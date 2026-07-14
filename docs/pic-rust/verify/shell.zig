// Thin "shell" module: imports the "engine" module's `engine_verify` export
// (defined in engine.zig, linked against the real, PIC-rebuilt
// librust_staticlib.a) and re-exports it under the WIT world's name so it
// can be invoked through `wasmtime run --invoke`.
extern fn engine_verify(a: i32, b: i32) i32;

export fn @"shell-call"(a: i32, b: i32) i32 {
    return engine_verify(a, b);
}
