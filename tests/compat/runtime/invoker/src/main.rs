// compat-invoker: a small host-side driver used only by
// tests/compat/runtime/run-bridge-tests.sh to instantiate a componentized
// Phase 0 compat fixture *once* and invoke one or more of its
// `starling:js/api` exports against that single instance, in order --
// something the `wasmtime` CLI's single-shot `--invoke` cannot do (each CLI
// process re-instantiates the component from its Wizer-frozen initial
// state). This is required to exercise the "repeated-calls" fixture's
// module-level JS state persisting across dispatches.
//
// Usage: compat-invoker <component.wasm> <calls.json>
//   calls.json: [{"function": "name", "args": [...]}, ...]
// Prints one JSON line per call to stdout, in order:
//   {"ok": true, "value": <json>}   -- call returned successfully
//   {"ok": false, "trap": "..."}    -- call trapped (e.g. the current
//                                      bridge's call-time missing/invalid
//                                      export failure; see js_dispatch.cpp)
//   {"ok": false, "trap": "post_return failed: ...",
//    "post_return_failed": true}   -- the call itself returned successfully,
//                                      but the canonical ABI's mandatory
//                                      `post_return` cleanup then trapped;
//                                      reported as a failed call (not a
//                                      PASS) so a post-return trap can never
//                                      be misattributed to the *next* call
//                                      in a sequence.
// A component instantiation failure is reported on stderr and exits 2.
use std::collections::HashMap;

use anyhow::{Context, Result};
use wasmtime::component::{Component, Linker, Type, Val};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{ResourceTable, WasiCtx, WasiCtxBuilder, WasiView};
use wasmtime_wasi::pipe::MemoryOutputPipe;
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpView};

struct Host {
    wasi: WasiCtx,
    http: WasiHttpCtx,
    table: ResourceTable,
}

impl WasiView for Host {
    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
    fn ctx(&mut self) -> &mut WasiCtx {
        &mut self.wasi
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

/// Resolves an export function by its bare name (e.g. "negate"), searching
/// both the component's top-level exports (the "interface-export-flattening"
/// shape used by some fixtures/examples) and one level of nested interface
/// instances (the `interface api { ... } world js-exports { export api; }`
/// shape produced by `gen_bridge_wit.py` for the compat fixtures). This
/// mirrors what `wasmtime run --invoke <name>(...)` does internally, since
/// fixture manifests only record bare function names.
///
/// NOTE: this dual lookup is a harness convenience, not evidence that the
/// bridge and reference componentized artifacts expose the same WIT
/// surface for a given fixture -- they don't. See manifest.json's
/// known_deviations "bridge-harness-starling-js-api-wrapping": the bridge
/// pipeline's output nests fixture functions one level down, under a
/// `starling:js/api` interface instance, while the reference pipeline's
/// output exports the same functions flat at the top level. This function
/// resolving both shapes uniformly must not be read as validating
/// interface-shape parity between the two pipelines.
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
                let iface_idx = instance
                    .get_export(&mut *store, None, export_name)
                    .with_context(|| format!("resolving interface export '{export_name}'"))?;
                let func_idx = instance
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


/// Calls `func` with `params`/`results`, then runs the canonical ABI's
/// mandatory `post_return` cleanup (only after a *successful* call: the
/// instance has no pending return to finalize after a trap, and Wasmtime
/// panics if `post_return` is invoked without a preceding successful
/// `call`). Returns the JSON record for this call plus the new stderr
/// buffer read position, both accounting for a `post_return` failure:
///
///   - call traps: `{"ok": false, "trap": "...", "diagnostics": "..."}`.
///   - call succeeds, `post_return` succeeds: `{"ok": true, "value": ...}`.
///   - call succeeds, `post_return` traps: the call's own success is
///     *not* reported -- reporting `{"ok": true, ...}` here would be a
///     false PASS (the instance never reached a clean post-call state,
///     which the canonical ABI requires before the next call/drop can be
///     considered well-formed) and could misattribute a later divergence
///     to the wrong call. Instead this returns a distinct
///     `{"ok": false, "trap": "post_return failed: ...",
///     "post_return_failed": true}` record so callers can tell this case
///     apart from an ordinary call-time trap.
fn call_and_finalize<T>(
    func: &wasmtime::component::Func,
    store: &mut Store<T>,
    params: &[Val],
    results: &mut [Val],
    stderr_pipe: &MemoryOutputPipe,
    stderr_pos: usize,
) -> (serde_json::Value, usize) {
    let mut stderr_pos = stderr_pos;
    let call_result = func.call(&mut *store, params, results);
    let mut record = match &call_result {
        Ok(()) => {
            let value = match results.len() {
                0 => serde_json::Value::Null,
                1 => val_to_json(&results[0]),
                _ => serde_json::Value::Array(results.iter().map(val_to_json).collect()),
            };
            serde_json::json!({"ok": true, "value": value})
        }
        Err(err) => {
            // Capture any new guest stderr output produced by this call
            // (e.g. js_dispatch's own panic diagnostic) alongside the
            // opaque wasm trap message, so callers can match on the
            // actual descriptive error text rather than just detecting
            // that *some* trap occurred.
            let all_stderr = stderr_pipe.contents();
            let new_stderr = String::from_utf8_lossy(&all_stderr[stderr_pos..]).into_owned();
            serde_json::json!({
                "ok": false,
                "trap": format!("{:#}", err),
                "diagnostics": new_stderr,
            })
        }
    };
    stderr_pos = stderr_pipe.contents().len();
    if call_result.is_ok() {
        // `post_return` must run before the next call reuses the same
        // instance/store (canonical ABI requirement).
        if let Err(post_return_err) = func.post_return(&mut *store) {
            let all_stderr = stderr_pipe.contents();
            let new_stderr = String::from_utf8_lossy(&all_stderr[stderr_pos..]).into_owned();
            stderr_pos = stderr_pipe.contents().len();
            record = serde_json::json!({
                "ok": false,
                "trap": format!("post_return failed: {:#}", post_return_err),
                "diagnostics": new_stderr,
                "post_return_failed": true,
            });
        }
    }
    (record, stderr_pos)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wasmtime::component::Linker;

    /// Builds and instantiates a no-imports component from WAT text, with a
    /// `MemoryOutputPipe`-backed WASI stderr so `call_and_finalize`'s
    /// diagnostics capture can be exercised without any real guest program.
    fn instantiate(
        wat: &str,
    ) -> (Engine, wasmtime::component::Instance, Store<Host>, MemoryOutputPipe) {
        let mut config = Config::new();
        config.wasm_component_model(true);
        let engine = Engine::new(&config).unwrap();
        let bytes = wat::parse_str(wat).expect("valid component WAT");
        let component = Component::from_binary(&engine, &bytes).expect("component compiles");
        let linker = Linker::<Host>::new(&engine);
        let stderr_pipe = MemoryOutputPipe::new(64 * 1024);
        let wasi = WasiCtxBuilder::new().stderr(stderr_pipe.clone()).build();
        let host = Host { wasi, http: WasiHttpCtx::new(), table: ResourceTable::new() };
        let mut store = Store::new(&engine, host);
        let instance = linker.instantiate(&mut store, &component).expect("instantiates");
        (engine, instance, store, stderr_pipe)
    }

    /// A component whose export's canonical-ABI `post-return` traps
    /// (`unreachable`) even though the call itself returns normally.
    const POST_RETURN_TRAPS_WAT: &str = r#"
        (component
          (core module $m
            (func (export "run") (result i32) i32.const 42)
            (func (export "run_post") (param i32) unreachable)
          )
          (core instance $i (instantiate $m))
          (func (export "run") (result u32)
            (canon lift (core func $i "run") (post-return (func $i "run_post"))))
        )
    "#;

    /// A component whose export's `post-return` returns normally.
    const POST_RETURN_OK_WAT: &str = r#"
        (component
          (core module $m
            (func (export "run") (result i32) i32.const 42)
            (func (export "run_post") (param i32))
          )
          (core instance $i (instantiate $m))
          (func (export "run") (result u32)
            (canon lift (core func $i "run") (post-return (func $i "run_post"))))
        )
    "#;

    #[test]
    fn post_return_trap_is_reported_as_failure_not_false_pass() {
        let (_engine, instance, mut store, stderr_pipe) = instantiate(POST_RETURN_TRAPS_WAT);
        let func = instance.get_func(&mut store, "run").expect("export exists");
        let mut results = vec![Val::Bool(false)];
        let (record, _pos) =
            call_and_finalize(&func, &mut store, &[], &mut results, &stderr_pipe, 0);

        assert_eq!(record["ok"], false, "a post_return trap must not be reported as ok:true");
        assert_eq!(record["post_return_failed"], true);
        let trap = record["trap"].as_str().unwrap();
        assert!(
            trap.starts_with("post_return failed:"),
            "expected a distinct post_return diagnostic, got {trap:?}"
        );
        // The call's own successful result must not leak through as a
        // (misleading) top-level "value" field on a failure record.
        assert!(record.get("value").is_none());
    }

    #[test]
    fn successful_post_return_still_reports_call_value() {
        let (_engine, instance, mut store, stderr_pipe) = instantiate(POST_RETURN_OK_WAT);
        let func = instance.get_func(&mut store, "run").expect("export exists");
        let mut results = vec![Val::Bool(false)];
        let (record, _pos) =
            call_and_finalize(&func, &mut store, &[], &mut results, &stderr_pipe, 0);

        assert_eq!(record["ok"], true);
        assert_eq!(record["value"], 42);
        assert!(record.get("post_return_failed").is_none());
    }
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let component_path = args
        .next()
        .context("usage: compat-invoker <component.wasm> <calls.json>")?;
    let calls_path = args
        .next()
        .context("usage: compat-invoker <component.wasm> <calls.json>")?;

    let calls: Vec<Call> = serde_json::from_str(
        &std::fs::read_to_string(&calls_path).context("reading calls.json")?,
    )
    .context("parsing calls.json")?;

    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, &component_path).context("loading component")?;

    let mut linker = Linker::<Host>::new(&engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker).context("linking wasi p2")?;
    // The full js-dispatch world also imports wasi:http; use the "only-http"
    // variant so it doesn't re-register wasi:clocks/random/etc. already
    // provided by `wasmtime_wasi::add_to_linker_sync` above.
    wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker).context("linking wasi-http")?;

    // Route the guest's own stdout (e.g. a fixture's `console.log`) to an
    // in-memory buffer instead of this process's real stdout: this tool's
    // stdout is reserved for the single JSON results array printed at the
    // end, and console output isn't part of what the compat fixtures
    // assert on (see `void` category cases' `notes`). Guest stdout is
    // still surfaced (on stderr) for debugging.
    //
    // Guest stderr is *also* captured (not just inherited) because the
    // js_dispatch glue's own diagnostic panic message -- e.g. "JavaScript
    // module export 'phantom' is not a function" for the negative fixtures
    // -- is printed there, not carried in the opaque wasm trap message
    // itself (which is just "wasm `unreachable` instruction executed").
    // The negative-fixture comparisons in run_bridge_tests.py match against
    // this captured text via the "diagnostics" field below.
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

    let instance = linker
        .instantiate(&mut store, &component)
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
        let param_tys = func.params(&store);
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
        let result_tys = func.results(&store);
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
