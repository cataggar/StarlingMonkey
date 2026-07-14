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
// Usage: wit-imports-invoker <component.wasm> <calls.json>
//        [--omit-boom] [--omit-root-boom]
//   calls.json: same shape as compat-invoker's (see main.rs) --
//   [{"function": "name", "args": [...]}, ...]
//   --omit-boom: don't register the `boom` host function at all, so
//   `linker.instantiate()` fails with an actionable "missing import"
//   message -- this drives the missing-import-diagnostics assertion in
//   run.sh; no calls are attempted in this mode (the process exits 2 with
//   the instantiation error printed to stderr, exactly like an ordinary
//   instantiation failure).
//   --omit-root-boom: the equivalent diagnostic probe for the world-level
//   `root-boom` function import.
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
// main.rs for the full rationale comments on each, including the JSON
// conventions for `char`/`tuple`/`enum`/`flags`/`variant`/`result<T,E>`
// (a direct `list<u8>` needs no special case here: at the Wasmtime `Val`
// level it is an ordinary `Type::List`/`Val::List` of `U8`s, same as any
// other `list<T>` -- the `Uint8Array` shape is purely a JS-side/component
// concern, asserted in component.js, not something this invoker's JSON
// bridge needs to know about).
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
        // JSON has no native spelling for option<option<T>>::none versus
        // some(none). For this E2E driver's nested-option probes, use the
        // same tagged JavaScript shape ComponentizeJS exposes.
        (Type::Option(opt_ty), J::Object(obj)) if matches!(opt_ty.ty(), Type::Option(_)) => {
            match obj.get("tag").and_then(|v| v.as_str()) {
                Some("none") => Val::Option(None),
                Some("some") => Val::Option(Some(Box::new(json_to_val(
                    &opt_ty.ty(),
                    obj.get("val").context("nested option 'some' requires 'val'")?,
                )?))),
                Some(other) => anyhow::bail!("nested option tag must be 'none' or 'some', got '{}'", other),
                None => anyhow::bail!("nested option JSON requires a string 'tag'"),
            }
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

fn add_root_imports(linker: &mut Linker<Host>, include_root_boom: bool) -> Result<()> {
    let mut root = linker.root();

    root.func_new(
        "add-one",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::U32(value) = &args[0] else {
                return Err(wasm_err("add-one: expected u32"));
            };
            results[0] = Val::U32(value.wrapping_add(1));
            Ok(())
        },
    )?;

    let note_count = Arc::new(AtomicU32::new(0));
    root.func_new("root-note", {
        let note_count = note_count.clone();
        move |_store, _ty, _args: &[Val], _results: &mut [Val]| -> wasmtime::Result<()> {
            note_count.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    })?;
    root.func_new("root-note-count", {
        let note_count = note_count.clone();
        move |_store, _ty, _args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            results[0] = Val::U32(note_count.load(Ordering::SeqCst));
            Ok(())
        }
    })?;

    if include_root_boom {
        root.func_new(
            "root-boom",
            |_store, _ty, _args: &[Val], _results: &mut [Val]| -> wasmtime::Result<()> {
                Err(wasm_err("root-boom: deliberate host-side trap"))
            },
        )?;
    }

    root.func_new(
        "root-transform",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Record(message) = &args[0] else {
                return Err(wasm_err("root-transform: expected root-message record"));
            };
            let Some((_, Val::Record(coordinate))) = message.iter().find(|(name, _)| name == "coordinate") else {
                return Err(wasm_err("root-transform: missing coordinate record"));
            };
            let Some((_, Val::U32(x))) = coordinate.iter().find(|(name, _)| name == "x") else {
                return Err(wasm_err("root-transform: coordinate.x must be u32"));
            };
            let Some((_, Val::U32(y))) = coordinate.iter().find(|(name, _)| name == "y") else {
                return Err(wasm_err("root-transform: coordinate.y must be u32"));
            };
            let Some((_, Val::List(labels))) = message.iter().find(|(name, _)| name == "labels") else {
                return Err(wasm_err("root-transform: labels must be list<string>"));
            };
            let mut transformed_labels = Vec::with_capacity(labels.len() + 1);
            for label in labels.iter().rev() {
                let Val::String(label) = label else {
                    return Err(wasm_err("root-transform: labels must be list<string>"));
                };
                transformed_labels.push(Val::String(label.clone()));
            }
            transformed_labels.push(Val::String("host".to_string()));
            results[0] = Val::Variant(
                "accepted".to_string(),
                Some(Box::new(Val::Record(vec![
                    (
                        "coordinate".to_string(),
                        Val::Record(vec![
                            ("x".to_string(), Val::U32(x.wrapping_add(1))),
                            ("y".to_string(), Val::U32(y.wrapping_add(2))),
                        ]),
                    ),
                    ("labels".to_string(), Val::List(transformed_labels)),
                ]))),
            );
            Ok(())
        },
    )?;

    Ok(())
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

    // -- advanced synchronous value types (requirement 5): every
    // synchronous type the native bridge supports for exports, now also
    // wired through the reverse (JS-imports) direction -- see
    // ../../../../e2e/wit-imports/wit/deps/test-wit-imports/package.wit's
    // doc comment for the upstream cataggar/wabt fix (PR #335) that made
    // this possible, and component.js for the JS-side assertions --

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

    // `char`/`option<char>`: shifts the codepoint by one -- proves real
    // host computation, not a bare passthrough.
    fn shift_char(c: char) -> char {
        char::from_u32((c as u32).wrapping_add(1)).unwrap_or('\u{FFFD}')
    }

    host.func_new(
        "identity-char",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Char(c) = &args[0] else {
                return Err(wasm_err("identity-char: expected char"));
            };
            results[0] = Val::Char(shift_char(*c));
            Ok(())
        },
    )?;

    host.func_new(
        "identity-option-char",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Option(opt) = &args[0] else {
                return Err(wasm_err("identity-option-char: expected option<char>"));
            };
            results[0] = match opt {
                None => Val::Option(None),
                Some(inner) => {
                    let Val::Char(c) = inner.as_ref() else {
                        return Err(wasm_err("identity-option-char: expected option<char>"));
                    };
                    Val::Option(Some(Box::new(Val::Char(shift_char(*c)))))
                }
            };
            Ok(())
        },
    )?;

    // `list<u8>` (bytes): `sum-bytes` proves a direct `list<u8>`
    // *parameter* lowers correctly; `xor-bytes` proves a direct `list<u8>`
    // *result* lifts correctly; `identity-optional-bytes` covers the
    // nested/optional case.
    host.func_new(
        "sum-bytes",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::List(items) = &args[0] else {
                return Err(wasm_err("sum-bytes: expected list<u8>"));
            };
            let mut sum: u32 = 0;
            for item in items {
                let Val::U8(v) = item else {
                    return Err(wasm_err("sum-bytes: expected list<u8> elements"));
                };
                sum = sum.wrapping_add(*v as u32);
            }
            results[0] = Val::U32(sum);
            Ok(())
        },
    )?;

    host.func_new(
        "xor-bytes",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let (Val::List(items), Val::U8(key)) = (&args[0], &args[1]) else {
                return Err(wasm_err("xor-bytes: expected (list<u8>, u8)"));
            };
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let Val::U8(v) = item else {
                    return Err(wasm_err("xor-bytes: expected list<u8> elements"));
                };
                out.push(Val::U8(v ^ key));
            }
            results[0] = Val::List(out);
            Ok(())
        },
    )?;

    host.func_new(
        "identity-optional-bytes",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Option(opt) = &args[0] else {
                return Err(wasm_err("identity-optional-bytes: expected option<list<u8>>"));
            };
            results[0] = match opt {
                None => Val::Option(None),
                Some(inner) => {
                    let Val::List(items) = inner.as_ref() else {
                        return Err(wasm_err("identity-optional-bytes: expected option<list<u8>>"));
                    };
                    let mut reversed = items.clone();
                    reversed.reverse();
                    Val::Option(Some(Box::new(Val::List(reversed))))
                }
            };
            Ok(())
        },
    )?;

    host.func_new(
        "describe-nested-option",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Record(fields) = &args[0] else {
                return Err(wasm_err("describe-nested-option: expected nested-option-argument"));
            };
            let outer = fields
                .iter()
                .find(|(name, _)| name == "nested")
                .map(|(_, value)| value)
                .ok_or_else(|| wasm_err("describe-nested-option: missing 'nested' field"))?;
            let Val::Option(outer) = outer else {
                return Err(wasm_err("describe-nested-option: expected option<option<u32>> field"));
            };
            results[0] = Val::String(match outer {
                None => "none".to_string(),
                Some(inner) => match inner.as_ref() {
                    Val::Option(None) => "some-none".to_string(),
                    Val::Option(Some(value)) => match value.as_ref() {
                        Val::U32(value) => format!("some-some-{value}"),
                        _ => return Err(wasm_err("describe-nested-option: expected u32 payload")),
                    },
                    _ => return Err(wasm_err("describe-nested-option: expected inner option")),
                },
            });
            Ok(())
        },
    )?;

    host.func_new(
        "identity-nested-option",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Record(fields) = &args[0] else {
                return Err(wasm_err("identity-nested-option: expected nested-option-argument"));
            };
            results[0] = Val::Record(fields.clone());
            Ok(())
        },
    )?;

    // `tuple`: swaps position and type, and transforms both elements
    // (increments the number, upper-cases the string) to prove real host
    // computation rather than a bare positional passthrough.
    host.func_new(
        "swap-tuple",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Tuple(items) = &args[0] else {
                return Err(wasm_err("swap-tuple: expected tuple<u32, string>"));
            };
            let [Val::U32(n), Val::String(s)] = &items[..] else {
                return Err(wasm_err("swap-tuple: expected tuple<u32, string>"));
            };
            results[0] = Val::Tuple(vec![Val::String(s.to_uppercase()), Val::U32(n.wrapping_add(1))]);
            Ok(())
        },
    )?;

    // `enum`/`option<enum>`: cycles red -> green -> blue -> red.
    fn next_color(c: &str) -> wasmtime::Result<&'static str> {
        Ok(match c {
            "red" => "green",
            "green" => "blue",
            "blue" => "red",
            other => return Err(wasm_err(format!("next-color: unknown case '{other}'"))),
        })
    }

    host.func_new(
        "next-color",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Enum(c) = &args[0] else {
                return Err(wasm_err("next-color: expected enum color"));
            };
            results[0] = Val::Enum(next_color(c)?.to_string());
            Ok(())
        },
    )?;

    host.func_new(
        "next-option-color",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Option(opt) = &args[0] else {
                return Err(wasm_err("next-option-color: expected option<color>"));
            };
            results[0] = match opt {
                None => Val::Option(None),
                Some(inner) => {
                    let Val::Enum(c) = inner.as_ref() else {
                        return Err(wasm_err("next-option-color: expected option<color>"));
                    };
                    Val::Option(Some(Box::new(Val::Enum(next_color(c)?.to_string()))))
                }
            };
            Ok(())
        },
    )?;

    // `flags`/`option<flags>` (3 labels): flips every bit.
    const PERMISSION_LABELS: [&str; 3] = ["read", "write", "execute"];
    fn toggle_permissions(set: &[String]) -> Vec<String> {
        PERMISSION_LABELS
            .iter()
            .filter(|name| !set.iter().any(|s| s == *name))
            .map(|s| s.to_string())
            .collect()
    }

    host.func_new(
        "toggle-permissions",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Flags(set) = &args[0] else {
                return Err(wasm_err("toggle-permissions: expected flags permissions"));
            };
            results[0] = Val::Flags(toggle_permissions(set));
            Ok(())
        },
    )?;

    host.func_new(
        "toggle-option-permissions",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Option(opt) = &args[0] else {
                return Err(wasm_err("toggle-option-permissions: expected option<permissions>"));
            };
            results[0] = match opt {
                None => Val::Option(None),
                Some(inner) => {
                    let Val::Flags(set) = inner.as_ref() else {
                        return Err(wasm_err("toggle-option-permissions: expected option<permissions>"));
                    };
                    Val::Option(Some(Box::new(Val::Flags(toggle_permissions(set)))))
                }
            };
            Ok(())
        },
    )?;

    // `variant` (one void case, two payload cases of different types):
    // `empty` -> `circle(1)`; `circle(r)` -> `circle(r * 2)`; `named(s)`
    // -> `named(s + "!")` -- exercises every case, including the void
    // one, with a real deterministic transform. `u32` (not `f64`) is
    // deliberately used for `circle`'s payload -- see package.wit's doc
    // comment on the `shape` variant for why a float payload sharing a
    // variant slot with a non-float payload hits an unrelated,
    // pre-existing `wit_types.zig` flat-ABI bug, out of this
    // integration's scope.
    host.func_new(
        "identity-shape",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::Variant(tag, payload) = &args[0] else {
                return Err(wasm_err("identity-shape: expected variant shape"));
            };
            results[0] = match (tag.as_str(), payload) {
                ("empty", None) => Val::Variant("circle".to_string(), Some(Box::new(Val::U32(1)))),
                ("circle", Some(p)) => {
                    let Val::U32(r) = p.as_ref() else {
                        return Err(wasm_err("identity-shape: circle payload must be u32"));
                    };
                    Val::Variant("circle".to_string(), Some(Box::new(Val::U32(r.wrapping_mul(2)))))
                }
                ("named", Some(p)) => {
                    let Val::String(s) = p.as_ref() else {
                        return Err(wasm_err("identity-shape: named payload must be string"));
                    };
                    Val::Variant("named".to_string(), Some(Box::new(Val::String(format!("{s}!")))))
                }
                (other, _) => return Err(wasm_err(format!("identity-shape: unrecognized case '{other}'"))),
            };
            Ok(())
        },
    )?;

    // `result<T, E>`: `checked-div` covers the both-payload form (`err` on
    // division by zero); `validate-non-negative` covers the void-ok-payload
    // form (`ok` carries nothing, `err` carries the reason). Neither gets
    // ComponentizeJS's throw-means-err convention here -- that is an
    // *export's own top-level return type* calling convention only (see
    // component.js); a host import always yields the ordinary `{tag, val}`
    // object to its JS caller.
    host.func_new(
        "checked-div",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let (Val::S32(a), Val::S32(b)) = (&args[0], &args[1]) else {
                return Err(wasm_err("checked-div: expected (s32, s32)"));
            };
            results[0] = if *b == 0 {
                Val::Result(Err(Some(Box::new(Val::String("division by zero".to_string())))))
            } else {
                Val::Result(Ok(Some(Box::new(Val::S32(a.wrapping_div(*b))))))
            };
            Ok(())
        },
    )?;

    host.func_new(
        "validate-non-negative",
        |_store, _ty, args: &[Val], results: &mut [Val]| -> wasmtime::Result<()> {
            let Val::S32(n) = &args[0] else {
                return Err(wasm_err("validate-non-negative: expected s32"));
            };
            results[0] = if *n >= 0 {
                Val::Result(Ok(None))
            } else {
                Val::Result(Err(Some(Box::new(Val::String("value is negative".to_string())))))
            };
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
    let omit_root_boom = if let Some(pos) = args.iter().position(|a| a == "--omit-root-boom") {
        args.remove(pos);
        true
    } else {
        false
    };
    let mut args = args.into_iter();
    let component_path = args
        .next()
        .context(
            "usage: wit-imports-invoker <component.wasm> <calls.json> \
             [--omit-boom] [--omit-root-boom]",
        )?;
    let calls_path = args
        .next()
        .context(
            "usage: wit-imports-invoker <component.wasm> <calls.json> \
             [--omit-boom] [--omit-root-boom]",
        )?;

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
    add_root_imports(&mut linker, !omit_root_boom).context("registering root function imports")?;

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

    // In either omit mode, this is expected to fail with Wasmtime's own
    // "missing import" diagnostic. That failure is the assertion in run.sh.
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
