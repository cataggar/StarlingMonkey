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
// Wasmtime >= 42 moved the WASIp2 linker helpers and the in-memory pipe
// types under a dedicated `p2` module (previously at the crate root); see
// `wasmtime_wasi::p2::add_to_linker_sync` below and this repository's
// invoker/rust-toolchain.toml / README.md "Wasmtime version" section for
// why this crate can take that newer API while the rest of this repository
// stays on rustc 1.88.0/an older API surface it doesn't depend on.
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{ResourceTable, WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpView};

struct Host {
    wasi: WasiCtx,
    http: WasiHttpCtx,
    table: ResourceTable,
}

impl WasiView for Host {
    // Wasmtime >= 42's `WasiView` trait dropped the separate `table()`
    // method in favor of a single `ctx()` returning a `WasiCtxView` that
    // bundles both the `WasiCtx` and the `ResourceTable` together.
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
        (Type::Char, J::String(s)) => {
            let mut chars = s.chars();
            let c = chars
                .next()
                .with_context(|| format!("expected a single-character string for char, got '{}'", s))?;
            if chars.next().is_some() {
                anyhow::bail!("expected exactly one Unicode scalar value for char, got '{}'", s);
            }
            Val::Char(c)
        }
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
        (Type::Tuple(tuple_ty), J::Array(items)) => {
            let elem_types: Vec<Type> = tuple_ty.types().collect();
            if elem_types.len() != items.len() {
                anyhow::bail!(
                    "tuple arity mismatch: expected {} elements, got {}",
                    elem_types.len(),
                    items.len()
                );
            }
            let mut vals = Vec::with_capacity(items.len());
            for (elem_ty, item) in elem_types.iter().zip(items) {
                vals.push(json_to_val(elem_ty, item)?);
            }
            Val::Tuple(vals)
        }
        (Type::Enum(enum_ty), J::String(s)) => {
            if !enum_ty.names().any(|n| n == s) {
                anyhow::bail!("unknown enum case '{}'", s);
            }
            Val::Enum(s.clone())
        }
        // Flags are encoded as a JSON array of the *set* flag names (order-
        // independent), matching `Val::Flags`' own representation (a list
        // of set names, not a full name->bool map).
        (Type::Flags(flags_ty), J::Array(items)) => {
            let valid: Vec<&str> = flags_ty.names().collect();
            let mut set = Vec::with_capacity(items.len());
            for item in items {
                let name = item.as_str().context("expected a flag name string")?;
                if !valid.contains(&name) {
                    anyhow::bail!("unknown flag '{}'", name);
                }
                set.push(name.to_string());
            }
            Val::Flags(set)
        }
        // Variants/results are encoded uniformly as `{"tag": "<case>", "val":
        // <payload, omitted if the case has none>}` -- a `result<T,E>` is
        // just a 2-case variant with fixed tag names `ok`/`err`.
        (Type::Variant(variant_ty), J::Object(obj)) => {
            let tag = obj
                .get("tag")
                .and_then(|v| v.as_str())
                .context("variant JSON requires a string 'tag'")?;
            let case = variant_ty
                .cases()
                .find(|c| c.name == tag)
                .with_context(|| format!("unknown variant case '{}'", tag))?;
            let payload = match case.ty {
                Some(ty) => Some(Box::new(json_to_val(
                    &ty,
                    obj.get("val")
                        .with_context(|| format!("variant case '{}' has a payload but JSON has no 'val'", tag))?,
                )?)),
                None => None,
            };
            Val::Variant(tag.to_string(), payload)
        }
        (Type::Result(result_ty), J::Object(obj)) => {
            let tag = obj
                .get("tag")
                .and_then(|v| v.as_str())
                .context("result JSON requires a string 'tag' of 'ok' or 'err'")?;
            match tag {
                "ok" => {
                    let payload = match result_ty.ok() {
                        Some(ty) => Some(Box::new(json_to_val(
                            &ty,
                            obj.get("val").context("result ok-case has a payload but JSON has no 'val'")?,
                        )?)),
                        None => None,
                    };
                    Val::Result(Ok(payload))
                }
                "err" => {
                    let payload = match result_ty.err() {
                        Some(ty) => Some(Box::new(json_to_val(
                            &ty,
                            obj.get("val").context("result err-case has a payload but JSON has no 'val'")?,
                        )?)),
                        None => None,
                    };
                    Val::Result(Err(payload))
                }
                other => anyhow::bail!("result tag must be 'ok' or 'err', got '{}'", other),
            }
        }
        // Contract probes need to distinguish option<option<T>>::none from
        // option<option<T>>::some(none), which plain JSON null cannot do.
        // Keep null as the legacy shorthand and accept an explicit tagged
        // form for nested option inputs.
        (Type::Option(_), J::Object(obj))
            if obj.get("$option").and_then(J::as_str) == Some("none") =>
        {
            Val::Option(None)
        }
        (Type::Option(opt_ty), J::Object(obj))
            if obj.get("$option").and_then(J::as_str) == Some("some") =>
        {
            let inner = obj
                .get("value")
                .context("tagged option some-case requires a 'value' field")?;
            Val::Option(Some(Box::new(json_to_val(&opt_ty.ty(), inner)?)))
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
        Val::Tuple(items) => J::Array(items.iter().map(val_to_json).collect()),
        Val::Enum(name) => J::String(name.clone()),
        Val::Flags(names) => J::Array(names.iter().map(|n| J::String(n.clone())).collect()),
        Val::Variant(tag, payload) => {
            let mut map = serde_json::Map::new();
            map.insert("tag".to_string(), J::String(tag.clone()));
            if let Some(p) = payload {
                map.insert("val".to_string(), val_to_json(p));
            }
            J::Object(map)
        }
        Val::Result(Ok(payload)) => {
            let mut map = serde_json::Map::new();
            map.insert("tag".to_string(), J::String("ok".to_string()));
            if let Some(p) = payload {
                map.insert("val".to_string(), val_to_json(p));
            }
            J::Object(map)
        }
        Val::Result(Err(payload)) => {
            let mut map = serde_json::Map::new();
            map.insert("tag".to_string(), J::String("err".to_string()));
            if let Some(p) = payload {
                map.insert("val".to_string(), val_to_json(p));
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

/// Resolves a function only through the exact `starling:js/api` interface
/// exported by every compat fixture. There is deliberately no top-level or
/// "first nested interface containing this name" fallback: either pipeline
/// changing topology must fail the same harness instead of being normalized
/// away by its invoker.
fn resolve_func(
    instance: &wasmtime::component::Instance,
    store: &mut Store<Host>,
    component: &Component,
    engine: &Engine,
    name: &str,
) -> Result<wasmtime::component::Func> {
    const INTERFACE: &str = "starling:js/api";
    let interface_ty = component
        .component_type()
        .exports(engine)
        .find_map(|(export_name, item)| (export_name == INTERFACE).then_some(item))
        .with_context(|| format!("component does not export exact interface '{INTERFACE}'"))?;
    let wasmtime::component::types::ComponentItem::ComponentInstance(iface) = interface_ty else {
        anyhow::bail!("component export '{INTERFACE}' is not an interface instance");
    };
    if !iface
        .exports(engine)
        .any(|(function_name, _)| function_name == name)
    {
        anyhow::bail!("interface '{INTERFACE}' does not export function '{name}'");
    }
    let (_, iface_idx) = instance
        .get_export(&mut *store, None, INTERFACE)
        .with_context(|| format!("resolving interface export '{INTERFACE}'"))?;
    let (_, func_idx) = instance
        .get_export(&mut *store, Some(&iface_idx), name)
        .with_context(|| format!("resolving function '{name}' in '{INTERFACE}'"))?;
    instance
        .get_func(&mut *store, &func_idx)
        .with_context(|| format!("export '{INTERFACE}#{name}' is not a function"))
}

/// Calls `func` with `params`/`results`. Returns the JSON record for this
/// call plus the new stderr buffer read position, both accounting for a
/// `post_return` failure:
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
///
/// Wasmtime >= 42 changed `wasmtime::component::Func::call` to run the
/// canonical ABI's mandatory `post-return` cleanup itself, as an
/// inseparable final step of the very same call (see its own doc comment:
/// "This will also call the corresponding post-return function, if any.");
/// the previously separate `Func::post_return` method is now a deprecated
/// no-op kept only for source compatibility (calling it is unnecessary and
/// has no effect). This is actually a strengthening of the invariant this
/// function exists to guarantee: a post-return trap can no longer be
/// silently swallowed as a false `ok:true` PASS *by construction*, since
/// `call` itself now returns `Err` unconditionally in that case, for every
/// caller of the `wasmtime` crate, not just this one.
///
/// What Wasmtime no longer exposes is *which* phase of a single failing
/// `call` actually trapped, since `results` are already lifted from the
/// callee's return values before the post-return step runs. This function
/// recovers that distinction the same way the trap itself is
/// distinguishable: by comparing `results`' `Debug` representation (`Val`
/// has no `PartialEq` impl) before and after the call. `call`'s own docs
/// state its initial values are ignored and always overwritten on success,
/// so if a trapping call nonetheless left `results` changed away from the
/// caller-supplied placeholders, the call body itself must have completed
/// (writing real results) before post-return then failed.
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
            // Capture any new guest stderr output produced by this call
            // (e.g. js_dispatch's own panic diagnostic) alongside the
            // opaque wasm trap message, so callers can match on the
            // actual descriptive error text rather than just detecting
            // that *some* trap occurred.
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
    let component = Component::from_file(&engine, &component_path)
        .map_err(anyhow::Error::from)
        .context("loading component")?;

    let mut linker = Linker::<Host>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
        .map_err(anyhow::Error::from)
        .context("linking wasi p2")?;
    // The full js-dispatch world also imports wasi:http; use the "only-http"
    // variant so it doesn't re-register wasi:clocks/random/etc. already
    // provided by `wasmtime_wasi::p2::add_to_linker_sync` above.
    wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker)
        .map_err(anyhow::Error::from)
        .context("linking wasi-http")?;

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
        // Wasmtime >= 42 removed `Func::params`/`Func::results`; the same
        // information is now reached via `Func::ty`, which returns a
        // `ComponentFunc` type descriptor with `params()`/`results()`
        // iterators (see wasmtime::component::types::ComponentFunc).
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
