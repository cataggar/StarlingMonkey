// Minimal "engine" root module used only to prove that
// target/wasm32-wasip1/release/librust_staticlib.a -- rebuilt with
// `-C relocation-model=pic` via deps/build-deps.sh -- can be linked
// (not merely inspected) into a `wasm32-wasi -dynamic -fPIC` module.
//
// The extern declarations below are real, exported (`#[no_mangle] pub
// extern "C"`) symbols from three different crates bundled into
// rust-staticlib (see runtime/crates/staticlib-template and
// deps/build-deps.sh step 3), not synthetic stand-ins:
//   - install_rust_hooks   (crates/rust-hooks/src/lib.rs)
//   - multipart_parser_new/_free (crates/rust-multipart/src/capi.rs)
//   - new_jsurl/free_jsurl (crates/rust-url/src/lib.rs)
//
// `zig build-lib` performs a real wasm-ld link when combining this file
// with the archive; if the archive still contained absolute-address
// relocations (R_WASM_MEMORY_ADDR_LEB/SLEB/I32) against non-PIC symbols,
// linking with `-dynamic -fPIC` below would fail exactly like the
// world-shell-spike `engine-dylib-experiment` failure recorded in
// docs/world-shell-spike/engine-pic-fail.excerpt.log.

extern fn install_rust_hooks() void;

// rust-hooks declares `#[link(name = "wrappers")] extern "C" { fn
// RustMozCrash(...) -> !; }` (crates/rust-hooks/src/lib.rs), implemented in
// the real build by crates/rust-hooks/src/wrappers.cpp against
// SpiderMonkey's MOZ_Crash. That C++ TU is compiled separately by the main
// StarlingMonkey build, not bundled into librust_staticlib.a, so this
// narrow verification (which only links the Rust archive) supplies a
// minimal stand-in satisfying the same "provided by the surrounding
// runtime" contract, exactly like the real build does.
export fn RustMozCrash(filename: [*:0]const u8, line: c_int, reason: [*:0]const u8) noreturn {
    _ = filename;
    _ = line;
    _ = reason;
    @trap();
}

const Slice = extern struct {
    data: [*]const u8,
    len: usize,
};

extern fn multipart_parser_new(data: *Slice, boundary: [*:0]const u8) ?*anyopaque;
extern fn multipart_parser_free(state: ?*anyopaque) void;

// Layout must match crates/rust-url/src/lib.rs's `#[repr(C)] SpecString`.
const SpecString = extern struct {
    data: [*]u8,
    len: usize,
    cap: usize,
};

extern fn new_jsurl(spec: *const SpecString) ?*anyopaque;
extern fn free_jsurl(url: ?*anyopaque) void;

/// Exercises real exports from rust-hooks, rust-multipart and rust-url in
/// one call, so a successful link+run proves the whole bundled archive
/// (not just one crate) is usable from a PIC dylib. Returns
/// `a + b + 100` when every call round-trips successfully, or a value
/// less than that (indicating which step failed) otherwise -- see
/// build-and-verify.sh for the exact expected value.
export fn engine_verify(a: i32, b: i32) i32 {
    install_rust_hooks();

    var body = "--B\r\nContent-Disposition: form-data\r\n\r\nx\r\n--B--\r\n".*;
    var slice = Slice{ .data = &body, .len = body.len };
    const parser = multipart_parser_new(&slice, "B");
    if (parser == null) return a + b;
    multipart_parser_free(parser);

    var spec_buf = "https://example.com/path".*;
    const spec = SpecString{ .data = &spec_buf, .len = spec_buf.len, .cap = spec_buf.len };
    const url = new_jsurl(&spec);
    if (url == null) return a + b + 10;
    free_jsurl(url);

    return a + b + 100;
}
