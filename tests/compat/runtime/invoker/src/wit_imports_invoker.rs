// wit-imports-invoker: a second, standalone host-side driver, added
// specifically for tests/e2e/wit-imports/run.sh. Unlike `compat-invoker`
// (which only *consumes* WIT-described exports), this binary additionally
// *implements* a custom WIT interface import
// (`test:wit-imports/host@1.2.3`) using Wasmtime's dynamic
// `LinkerInstance::func_new` API, so the componentized fixture's
// JS-side `import ... from "test:wit-imports/host@1.2.3"` has a real host
// function to call through the reverse canonical-ABI bridge
// (runtime/js_dispatch.{h,cpp,zig} + WABT's `--js-imports` codegen).
//
// This intentionally does NOT touch main.rs/compat-invoker (kept as its own
// `[[bin]]` target in the same crate/dependency-pinned workspace) so the
// existing 11/11 compat suite can't regress from this addition.
//
// Usage: wit-imports-invoker <component.wasm> <calls.json> [--omit-boom]
//   calls.json: same shape as compat-invoker's (see main.rs) --
//   [{"function": "name", "args": [...]}, ...]
//   --omit-boom: don't register the `boom` host function at all, so
//   `linker.instantiate()` fails with an actionable "missing import"
//   message -- this drives the missing-import-diagnostics assertion in
//   run.sh; no calls are attempted in this mode (the process exits 2 with
//   the instantiation error printed to stderr, exactly like an ordinary
//   instantiation failure).
//
// Prints one JSON line (a JSON array, one record per call) to stdout, in
// the exact same `{"ok": ..., ...}` shape as compat-invoker.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use wasmtime::component::{Component, Linker, Type, Val};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{ResourceTable, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpView};

struct Host {
    wasi: WasiCtx,
    http: WasiHttpCtx,
    table: ResourceTable,
}

impl WasiView for Host {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl WasiHttpView for Host {
    fn ctx(&mut self) -> &mut WasiHttpCtx {
        &mut self.http
    }
    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
}

// json_to_val / val_to_json / resolve_func / call_and_finalize below are
// deliberately near-identical copies of the same-named helpers in
// main.rs (not shared via a lib crate, so this file can evolve
// independently without risking the reviewed compat-invoker binary). See
// main.rs for the full rationale comments on each.
fn json_to_val(ty: &Type, value: &serde_json::Value) -> Result<Val> {
    use serde_json::Value as J;
    Ok(match (ty, value) {
        (Type::Bool, J::Bool(b)) => Val::Bool(*b),
        (Type::U8, v) => Val::U8(v.as_u64().context("expected u8")? as u8),
        (Type::U16, v) => Val::U16(v.as_u64().context("expected u16")? as u16),
        (Type::U32, v) => Val::U32(v.as_u64().context("expected u32")? as u32),
        (Type::U64, v) => Val::U64(v.as_u64().context("expected u64")?),
        (Type::S8, v) => Val::S8(v.as_i64().context("expected s8")? as i8),
        (Type::S16, v) => Val::S16(v.as_i64().context("expected s16")? as i16),
        (Type::S32, v) => Val::S32(v.as_i64().context("expected s32")? as i32),
        (Type::S64, v) => Val::S64(v.as_i64().context("expected s64")?),
        (Type::Float32, v) => Val::Float32(v.as_f64().context("expected f32")? as f32),
        (Type::Float64, v) => Val::Float64(v.as_f64().context("expected f64")?),
        (Type::String, J::String(s)) => Val::String(s.clone()),
        (Type::List(list_ty), J::Array(items)) => {
            let elem_ty = list_ty.ty();
            let mut vals = Vec::with_capacity(items.len());
            for item in items {
                vals.push(json_to_val(&elem_ty, item)?);
            }
            Val::List(vals)
        }
        (Type::Record(record_ty), J::Object(fields)) => {
            let mut vals = Vec::new();
            for field in record_ty.fields() {
                let field_value = fields
                    .get(field.name)
                    .with_context(|| format!("missing record field '{}'", field.name))?;
                vals.push((field.name.to_string(), json_to_val(&field.ty, field_value)?));
            }
            Val::Record(vals)
        }
        (Type::Option(_), J::Null) => Val::Option(None),
        (Type::Option(opt_ty), v) => Val::Option(Some(Box::new(json_to_val(&opt_ty.ty(), v)?))),
        (ty, v) => anyhow::bail!("unsupported type/value combination: {:?} / {}", ty, v),
    })
}

fn val_to_json(val: &Val) -> serde_json::Value {
    use serde_json::Value as J;
    match val {
        Val::Bool(b) => J::Bool(*b),
        Val::U8(n) => J::from(*n),
        Val::U16(n) => J::from(*n),
        Val::U32(n) => J::from(*n),
        Val::U64(n) => J::from(*n),
        Val::S8(n) => J::from(*n),
        Val::S16(n) => J::from(*n),
        Val::S32(n) => J::from(*n),
        Val::S64(n) => J::from(*n),
        Val::Float32(n) => J::from(*n as f64),
        Val::Float64(n) => J::from(*n),
        Val::Char(c) => J::String(c.to_string()),
        Val::String(s) => J::String(s.clone()),
        Val::List(items) => J::Array(items.iter().map(val_to_json).collect()),
        Val::Record(fields) => {
            let mut map = serde_json::Map::new();
            for (name, v) in fields {
                map.insert(name.clone(), val_to_json(v));
            }
            J::Object(map)
        }
        Val::Option(None) => J::Null,
        Val::Option(Some(v)) => val_to_json(v),
        other => J::String(format!("{:?}", other)),
    }
}

#[derive(serde::Deserialize)]
struct Call {
    function: String,
    args: Vec<serde_json::Value>,
}

fn resolve_func(
    instance: &wasmtime::component::Instance,
    store: &mut Store<Host>,
    component: &Component,
    engine: &Engine,
    name: &str,
) -> Result<wasmtime::component::Func> {
    if let Some(f) = instance.get_func(&mut *store, name) {
        return Ok(f);
    }
    for (export_name, item) in component.component_type().exports(engine) {
        if let wasmtime::component::types::ComponentItem::ComponentInstance(iface) = item {
            if iface.exports(engine).any(|(fname, _)| fname == name) {
                let (_, iface_idx) = instance
                    .get_export(&mut *store, None, export_name)
                    .with_context(|| format!("resolving interface export '{export_name}'"))?;
                let (_, func_idx) = instance
                    .get_export(&mut *store, Some(&iface_idx), name)
                    .with_context(|| format!("resolving function '{name}' in '{export_name}'"))?;
                return instance
                    .get_func(&mut *store, &func_idx)
                    .with_context(|| format!("export '{export_name}#{name}' is not a function"));
            }
        }
    }
    anyhow::bail!("export '{}' not found (checked top-level and nested interfaces)", name)
}

fn call_and_finalize<T>(
    func: &wasmtime::component::Func,
    store: &mut Store<T>,
    params: &[Val],
    results: &mut [Val],
    stderr_pipe: &MemoryOutputPipe,
    stderr_pos: usize,
) -> (serde_json::Value, usize) {
    let results_before: Vec<String> = results.iter().map(|v| format!("{v:?}")).collect();
    let call_result = func.call(&mut *store, params, results);
    let record = match &call_result {
        Ok(()) => {
            let value = match results.len() {
                0 => serde_json::Value::Null,
                1 => val_to_json(&results[0]),
                _ => serde_json::Value::Array(results.iter().map(val_to_json).collect()),
            };
            serde_json::json!({"ok": true, "value": value})
        }
        Err(err) => {
            let all_stderr = stderr_pipe.contents();
            let new_stderr = String::from_utf8_lossy(&all_stderr[stderr_pos..]).into_owned();
            let results_after: Vec<String> = results.iter().map(|v| format!("{v:?}")).collect();
            let post_return_failed = !results.is_empty() && results_before != results_after;
            if post_return_failed {
                serde_json::json!({
                    "ok": false,
                    "trap": format!("post_return failed: {:#}", err),
                    "diagnostics": new_stderr,
                    "post_return_failed": true,
                })
            } else {
                serde_json::json!({
                    "ok": false,
                    "trap": format!("{:#}", err),
                    "diagnostics": new_stderr,
                })
            }
        }
    };
    let stderr_pos = stderr_pipe.contents().len();
    (record, stderr_pos)
}

/// The host-side implementation of `test:wit-imports/host@1.2.3`, registered
/// dynamically via `Linker::instance(..).func_new(..)` (the only Wasmtime
/// API able to supply a host implementation for a component-level import
/// that isn't one of the built-in `-S` WASI surfaces -- see the module doc
/// comment on why `wasmtime run --invoke` can't be used for this fixture).
///
/// `include_boom`: when false, `boom` is deliberately left unregistered so
/// `linker.instantiate()` fails with Wasmtime's own "missing import"
/// diagnostic, exercising requirement 5's "missing import diagnostics" case
/// end to end (a real Wasmtime error, not a StarlingMonkey-invented one).
///
/// NOTE: `LinkerInstance::func_new`'s closures must return
/// `wasmtime::Result<()>` (== `Result<(), wasmtime::Error>`), which is a
/// *distinct* type from `anyhow::Error` used everywhere else in this file
/// (Wasmtime 42 does not implement `From<anyhow::Error> for wasmtime::Error`,
/// only the reverse) -- so these closures build errors via
/// `wasmtime::Error::msg` instead of `anyhow::bail!`/`anyhow::Context`.
fn wasm_err(msg: impl Into<String>) -> wasmtime::Error {
    wasmtime::Error::msg(msg.into())
}

fn add_host_import(linker: &mut Linker<Host>, include_boom: bool) -> Result<()> {
    let mut host = linker.instance("test:wit-imports/host@1.2.3")?;

    host.func_new(
        "add",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let (Val::S64(a), Val::S64(b)) = (&args[0], &args[1]) else {
                return Err(wasm_err("add: expected (s64, s64)"));
            };
            // Exact 64-bit add; deliberately not routed through f64/JSON so
            // this proves the bridge's s64 path is exact end to end (the
            // JS side adds full-magnitude BigInts, e.g. i64::MIN + -1).
            results[0] = Val::S64(a.wrapping_add(*b));
            Ok(())
        },
    )?;

    host.func_new(
        "sum-list",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::List(items) = &args[0] else {
                return Err(wasm_err("sum-list: expected list<u64>"));
            };
            let mut sum: u64 = 0;
            for item in items {
                let Val::U64(v) = item else {
                    return Err(wasm_err("sum-list: expected list<u64> elements"));
                };
                sum = sum.wrapping_add(*v);
            }
            results[0] = Val::U64(sum);
            Ok(())
        },
    )?;

    host.func_new(
        "greet",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::String(name) = &args[0] else {
                return Err(wasm_err("greet: expected string"));
            };
            results[0] = Val::String(format!("Hello from host, {name}!"));
            Ok(())
        },
    )?;

    host.func_new(
        "scale",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let (Val::Record(fields), Val::U32(factor)) = (&args[0], &args[1]) else {
                return Err(wasm_err("scale: expected (record, u32)"));
            };
            let get = |name: &str| -> wasmtime::Result<u32> {
                for (fname, v) in fields {
                    if fname == name {
                        if let Val::U32(n) = v {
                            return Ok(*n);
                        }
                    }
                }
                Err(wasm_err(format!("scale: missing/wrong-typed field '{name}'")))
            };
            let x = get("x")?;
            let y = get("y")?;
            results[0] = Val::Record(vec![
                ("x".to_string(), Val::U32(x.wrapping_mul(*factor))),
                ("y".to_string(), Val::U32(y.wrapping_mul(*factor))),
            ]);
            Ok(())
        },
    )?;

    if include_boom {
        host.func_new(
            "boom",
            |_store, _ty, _args: &[Val], _results: &mut [Val]| -> wasmtime::Result<()> {
                // Always traps: proves a host-side error propagates all the
                // way back out through the JS import call and the wasm
                // export call as a genuine trap, per requirement 5.
                Err(wasm_err("boom: deliberate host-side trap"))
            },
        )?;
    }

    // `note`/`note-count`: a void host import (`note` has no WIT result)
    // plus a side-channel query import so the test can observe `note`'s
    // real side effect (this counter incrementing) rather than merely
    // asserting the JS call site didn't throw. Both share one counter via
    // `Arc<AtomicU32>` -- `func_new` closures must be `Send + Sync`, so
    // interior mutability (not a captured `&mut`) is required here.
    let note_count = Arc::new(AtomicU32::new(0));
    host.func_new("note", {
        let note_count = note_count.clone();
        move |_store, _ty, _args: &[Val], _results: &mut [Val]| -> wasmtime::Result<()> {
            note_count.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    })?;
    host.func_new("note-count", {
        let note_count = note_count.clone();
        move |_store, _ty, _args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            results[0] = Val::U32(note_count.load(Ordering::SeqCst));
            Ok(())
        }
    })?;

    // -- advanced synchronous value types (requirement 5), scoped to what
    // the pinned WABT's `--js-imports` bindgen currently accepts (see
    // ../../../../e2e/wit-imports/wit/deps/test-wit-imports/package.wit's
    // doc comment for why char/list<u8>/tuple/enum/flags/variant/result
    // are not wired in here) --

    host.func_new(
        "sum-nested-lists",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::List(rows) = &args[0] else {
                return Err(wasm_err("sum-nested-lists: expected list<list<u32>>"));
            };
            let mut sum: u32 = 0;
            for row in rows {
                let Val::List(items) = row else {
                    return Err(wasm_err("sum-nested-lists: expected list<u32> rows"));
                };
                for item in items {
                    let Val::U32(v) = item else {
                        return Err(wasm_err("sum-nested-lists: expected u32 elements"));
                    };
                    sum = sum.wrapping_add(*v);
                }
            }
            results[0] = Val::U32(sum);
            Ok(())
        },
    )?;

    Ok(())
}

fn main() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let omit_boom = if let Some(pos) = args.iter().position(|a| a == "--omit-boom") {
        args.remove(pos);
        true
    } else {
        false
    };
    let mut args = args.into_iter();
    let component_path = args
        .next()
        .context("usage: wit-imports-invoker <component.wasm> <calls.json> [--omit-boom]")?;
    let calls_path = args
        .next()
        .context("usage: wit-imports-invoker <component.wasm> <calls.json> [--omit-boom]")?;

    let calls: Vec<Call> = serde_json::from_str(
        &std::fs::read_to_string(&calls_path).context("reading calls.json")?,
    )
    .context("parsing calls.json")?;

    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, &component_path)
        .map_err(anyhow::Error::from)
        .context("loading component")?;

    let mut linker = Linker::<Host>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
        .map_err(anyhow::Error::from)
        .context("linking wasi p2")?;
    wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker)
        .map_err(anyhow::Error::from)
        .context("linking wasi-http")?;
    add_host_import(&mut linker, !omit_boom).context("registering test:wit-imports/host@1.2.3")?;

    let stdout_pipe = MemoryOutputPipe::new(64 * 1024);
    let stderr_pipe = MemoryOutputPipe::new(64 * 1024);
    let wasi = WasiCtxBuilder::new()
        .stderr(stderr_pipe.clone())
        .stdout(stdout_pipe.clone())
        .build();
    let host = Host {
        wasi,
        http: WasiHttpCtx::new(),
        table: ResourceTable::new(),
    };
    let mut store = Store::new(&engine, host);

    // In `--omit-boom` mode, this is expected to fail with Wasmtime's own
    // "missing import" diagnostic -- that failure IS the assertion (see
    // run.sh), so it's allowed to propagate via `?` and exit the process
    // with a non-zero status, same as any other instantiation error.
    let instance = linker
        .instantiate(&mut store, &component)
        .map_err(anyhow::Error::from)
        .context("instantiating component")?;

    let mut func_cache: HashMap<String, wasmtime::component::Func> = HashMap::new();
    let mut out = Vec::new();
    let mut stderr_pos = 0usize;
    for call in &calls {
        let func = match func_cache.get(&call.function) {
            Some(f) => *f,
            None => {
                let f = resolve_func(&instance, &mut store, &component, &engine, &call.function)?;
                func_cache.insert(call.function.clone(), f);
                f
            }
        };
        let func_ty = func.ty(&store);
        let param_tys: Vec<Type> = func_ty.params().map(|(_, ty)| ty).collect();
        let result_tys: Vec<Type> = func_ty.results().collect();
        if param_tys.len() != call.args.len() {
            anyhow::bail!(
                "function '{}' expects {} argument(s), got {}",
                call.function,
                param_tys.len(),
                call.args.len()
            );
        }
        let mut params = Vec::with_capacity(param_tys.len());
        for (ty, arg) in param_tys.iter().zip(&call.args) {
            params.push(json_to_val(ty, arg)?);
        }
        let mut results = vec![Val::Bool(false); result_tys.len()];
        let (record, new_stderr_pos) =
            call_and_finalize(&func, &mut store, &params, &mut results, &stderr_pipe, stderr_pos);
        stderr_pos = new_stderr_pos;
        out.push(record);
    }

    let captured_stdout = stdout_pipe.contents();
    if !captured_stdout.is_empty() {
        eprintln!(
            "--- guest stdout ---\n{}--- end guest stdout ---",
            String::from_utf8_lossy(&captured_stdout)
        );
    }

    println!("{}", serde_json::Value::Array(out));
    Ok(())
}
