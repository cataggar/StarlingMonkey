const std = @import("std");

// StarlingMonkey build (Zig 0.17 port of the CMake build).
//
// Toolchain: Zig 0.17 `zig cc`/`zig c++` targeting wasm32-wasi (reactor),
// replacing wasi-sdk. SpiderMonkey is built from source with the same Zig
// toolchain (the upstream prebuilt libspidermonkey.a is libc++-ABI-incompatible
// with Zig — see the zig17 conversion plan), producing a libc++ `__1` archive.

const Ctx = struct {
    b: *std.Build,
    cxx_flags: []const []const u8,
    c_flags: []const []const u8,
    common_includes: []const []const u8,
    builtins_incl_dir: std.Build.LazyPath,
    host_api_dir: []const u8,
    wasi020: []const u8,
    wasi023: []const u8,
};

// ---- Platform feature selection (cataggar/StarlingMonkey#6 Phase 6) ----
//
// ComponentizeJS-compatible platform feature defaults/disabling for stdio,
// random, clocks, http, and fetch-event. Mirrors the pinned ComponentizeJS
// 0.21.0 `componentize()` API's `disableFeatures`/`enableFeatures` naming
// (see docs/feature-selection/README.md for the full behavior matrix and
// documented deviations), but is threaded through typed Zig build options
// (`-Dfeature-*`) rather than environment variables, since this build
// produces the componentizer itself rather than consuming it as an npm API.
const FeatureName = enum {
    stdio,
    random,
    clocks,
    http,
    @"fetch-event",

    fn parse(name: []const u8) ?FeatureName {
        const info = @typeInfo(FeatureName).@"enum";
        inline for (info.field_names, 0..) |field_name, i| {
            if (std.mem.eql(u8, name, field_name)) return @enumFromInt(info.field_values[i]);
        }
        return null;
    }
};

const Features = struct {
    stdio: bool,
    random: bool,
    clocks: bool,
    http: bool,
    fetch_event: bool,

    fn get(self: Features, name: FeatureName) bool {
        return switch (name) {
            .stdio => self.stdio,
            .random => self.random,
            .clocks => self.clocks,
            .http => self.http,
            .@"fetch-event" => self.fetch_event,
        };
    }

    fn set(self: *Features, name: FeatureName, value: bool) void {
        switch (name) {
            .stdio => self.stdio = value,
            .random => self.random = value,
            .clocks => self.clocks = value,
            .http => self.http = value,
            .@"fetch-event" => self.fetch_event = value,
        }
    }
};

// Splits a comma-separated feature-name list, validating each entry against
// `FeatureName`. Unknown names and empty entries are hard build errors
// (`@panic`, aborting the build deterministically) -- this is an intentional,
// stricter-than-reference deviation: the pinned ComponentizeJS 0.21.0
// splicer silently ignores unknown `disableFeatures`/`enableFeatures` entries
// (empirically verified against the real npm package; see
// docs/feature-selection/README.md "Known deviations"), which this build
// treats as a conflict per task requirement #4 ("Do not silently fall
// back.").
fn parseFeatureList(gpa: std.mem.Allocator, opt_name: []const u8, csv: []const u8) []const FeatureName {
    var out: std.ArrayList(FeatureName) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const parsed = FeatureName.parse(name) orelse {
            std.debug.print(
                "error: -D{s}: unknown feature '{s}' (known features: stdio, random, clocks, http, fetch-event)\n",
                .{ opt_name, name },
            );
            @panic("unknown feature name");
        };
        out.append(gpa, parsed) catch @panic("OOM");
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

// Resolves the final `Features` selection from the typed `-Dfeature-*`
// booleans (defaults, matching ComponentizeJS 0.21.0's "all features enabled
// by default") plus the ComponentizeJS-CLI-ergonomic `-Ddisable-features`/
// `-Denable-features` comma lists layered on top. A feature named in both
// lists simultaneously is a deterministic build-time conflict (task
// requirement #4), unlike the reference (which silently accepts it).
fn resolveFeatures(b: *std.Build, defaults: Features) Features {
    const disable_csv = b.option([]const u8, "disable-features", "Comma-separated ComponentizeJS-style feature names to disable (stdio,random,clocks,http,fetch-event)");
    const enable_csv = b.option([]const u8, "enable-features", "Comma-separated feature names to explicitly (re-)enable, overriding -Ddisable-features");
    var features = defaults;
    const disabled = if (disable_csv) |csv| parseFeatureList(b.allocator, "disable-features", csv) else &.{};
    const enabled = if (enable_csv) |csv| parseFeatureList(b.allocator, "enable-features", csv) else &.{};
    for (disabled) |d| {
        for (enabled) |e| {
            if (d == e) {
                std.debug.print(
                    "error: feature '{s}' appears in both -Ddisable-features and -Denable-features\n",
                    .{@tagName(d)},
                );
                @panic("conflicting feature selection");
            }
        }
    }
    for (disabled) |d| features.set(d, false);
    for (enabled) |e| features.set(e, true);
    return features;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // StarlingMonkey only targets wasm32-wasi (reactor).
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    const enable_debugger = b.option(bool, "debugger", "Enable JS debugger socket support") orelse true;
    const host_api_name = b.option([]const u8, "host-api", "Host API implementation under host-apis/") orelse "wasi-0.2.10";
    const use_wasm_opt = b.option(bool, "wasm-opt", "Optimize starling-raw.wasm with wasm-opt for release builds") orelse true;
    const component_wit = b.option([]const u8, "component-wit", "WIT directory whose exported functions dispatch to JavaScript");
    const component_world = b.option([]const u8, "component-world", "World to generate JavaScript-backed exports for");
    if ((component_wit == null) != (component_world == null)) {
        @panic("-Dcomponent-wit and -Dcomponent-world must be provided together");
    }
    const dispatch_wit = b.option([]const u8, "dispatch-wit", "Export-only WIT directory used to generate JavaScript dispatch bindings") orelse component_wit;
    const dispatch_world = b.option([]const u8, "dispatch-world", "Export-only world used to generate JavaScript dispatch bindings") orelse component_world;
    if ((dispatch_wit == null) != (dispatch_world == null)) {
        @panic("-Ddispatch-wit and -Ddispatch-world must be provided together");
    }

    // Platform feature selection (cataggar/StarlingMonkey#6 Phase 6). Typed
    // per-feature booleans, all defaulting to enabled (matches ComponentizeJS
    // 0.21.0's "all features enabled by default"; see
    // docs/feature-selection/README.md).
    const feature_defaults = Features{
        .stdio = b.option(bool, "feature-stdio", "Enable WASI stdio (wasi:cli/stdin|stdout|stderr, preview1 fd_write/fd_fdstat_get); default true") orelse true,
        .random = b.option(bool, "feature-random", "Enable WASI random (wasi:random/random, preview1 random_get); default true") orelse true,
        .clocks = b.option(bool, "feature-clocks", "Enable WASI clocks (wasi:clocks/monotonic-clock|wall-clock, preview1 clock_time_get/clock_res_get); default true") orelse true,
        .http = b.option(bool, "feature-http", "Enable outgoing WASI HTTP requests (wasi:http/outgoing-handler, the fetch() call path); default true") orelse true,
        .fetch_event = b.option(bool, "feature-fetch-event", "Enable the incoming FetchEvent/http-incoming-handler surface (addEventListener('fetch', ...)); default true") orelse true,
    };
    const features = resolveFeatures(b, feature_defaults);

    // SpiderMonkey artifacts built from source with Zig (see deps/mozconfig-zig).
    const sm_dist = b.option([]const u8, "spidermonkey-dist", "Path to the Zig-built SpiderMonkey dist dir") orelse "deps/sm-obj-zig/dist";
    const sm_confdefs = b.option([]const u8, "spidermonkey-confdefs", "Path to js-confdefs.h") orelse "deps/sm-obj-zig/js/src/js-confdefs.h";
    const sm_include = b.pathJoin(&.{ sm_dist, "include" });
    const sm_lib = b.pathJoin(&.{ sm_dist, "libspidermonkey.a" });

    const is_debug = optimize == .Debug;
    const gpa = b.allocator;

    // ---- Common compile flags (port of cmake/compile-flags.cmake) ----
    // Differences from the wasi-sdk build:
    //   * `-m32` dropped (wasm32 is already 32-bit; zig cc rejects it).
    //   * `-lwasi-emulated-*` link flags dropped; Zig's wasi-libc provides those
    //     symbols when the `-D_WASI_EMULATED_*` defines are set.
    const wasi_emulated = [_][]const u8{
        "-D_WASI_EMULATED_SIGNAL",
        "-D_WASI_EMULATED_PROCESS_CLOCKS",
        "-D_WASI_EMULATED_GETPID",
    };

    var cxx_flags: std.ArrayList([]const u8) = .empty;
    var c_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(gpa, &.{
        "-std=gnu++23",
        "-Wall",
        "-Wno-unknown-warning-option",
        "-Wno-invalid-offsetof",
        "-Wno-unused-result",
        "-Wno-error=unused-result",
        "-Wimplicit-fallthrough",
        "-Qunused-arguments",
        "-fno-sized-deallocation",
        "-fno-aligned-new",
        "-mthread-model",
        "single",
        "-fPIC",
        "-fno-rtti",
        "-fno-exceptions",
        "-fno-math-errno",
        "-pipe",
        "-fno-omit-frame-pointer",
        "-funwind-tables",
        "-include",
        sm_confdefs,
    }) catch @panic("OOM");
    cxx_flags.appendSlice(gpa, &wasi_emulated) catch @panic("OOM");
    c_flags.appendSlice(gpa, &.{
        "-Wall",
        "-Wno-unknown-attributes",
        "-Wno-pointer-to-int-cast",
        "-Wno-int-to-pointer-cast",
    }) catch @panic("OOM");
    c_flags.appendSlice(gpa, &wasi_emulated) catch @panic("OOM");
    if (is_debug) cxx_flags.append(gpa, "-DDEBUG=1") catch @panic("OOM");
    if (enable_debugger) cxx_flags.append(gpa, "-DENABLE_JS_DEBUGGER") catch @panic("OOM");

    // Feature-selection macro defines (cataggar/StarlingMonkey#6 Phase 6),
    // consumed by host_api.cpp/timers.cpp/global-event-target.cpp/
    // feature_stubs.c (`#if STARLING_FEATURE_*`; default 1 if undefined).
    // Threaded to both C++ and C compile flags since feature_stubs.c (the
    // preview1-level stdio/random/clocks stubs) is a plain C source.
    const feature_defines = [_][]const u8{
        b.fmt("-DSTARLING_FEATURE_STDIO={d}", .{@intFromBool(features.stdio)}),
        b.fmt("-DSTARLING_FEATURE_RANDOM={d}", .{@intFromBool(features.random)}),
        b.fmt("-DSTARLING_FEATURE_CLOCKS={d}", .{@intFromBool(features.clocks)}),
        b.fmt("-DSTARLING_FEATURE_HTTP={d}", .{@intFromBool(features.http)}),
        b.fmt("-DSTARLING_FEATURE_FETCH_EVENT={d}", .{@intFromBool(features.fetch_event)}),
    };
    cxx_flags.appendSlice(gpa, &feature_defines) catch @panic("OOM");
    c_flags.appendSlice(gpa, &feature_defines) catch @panic("OOM");

    const common_includes = [_][]const u8{ "include", "deps/include", "runtime", sm_include };

    // ---- builtins.incl (port of cmake builtins.cmake NS_DEF generation) ----
    // When both `http` and `fetch-event` are disabled, the `fetch`/
    // `fetch_event` builtins are excluded entirely (deeper pruning than
    // just gating their host_api call sites: removes `fetch`/Request/
    // Response/Headers/FetchEvent as JS globals too, which lets wasm-ld
    // dead-code-eliminate the underlying wasi:http/types host imports from
    // the componentized surface). This is an intentional deviation from the
    // reference (whose splicer runs on the compiled binary and always
    // leaves the JS-facing `fetch`/Request/Response surface present,
    // failing only at the WASI-import call site) -- see
    // docs/feature-selection/README.md "Known deviations".
    const prune_fetch_builtins = !features.http and !features.fetch_event;
    const builtins_incl_base =
        \\// Generated by build.zig
        \\NS_DEF(builtins::web::global_self)
        \\NS_DEF(builtins::web::queue_microtask)
        \\NS_DEF(builtins::web::structured_clone)
        \\NS_DEF(builtins::web::base64)
        \\NS_DEF(builtins::web::blob)
        \\NS_DEF(builtins::web::file)
        \\NS_DEF(builtins::web::event)
        \\NS_DEF(builtins::web::abort)
        \\NS_DEF(builtins::web::form_data)
        \\NS_DEF(builtins::web::dom_exception)
        \\NS_DEF(builtins::web::url)
        \\NS_DEF(builtins::web::console)
        \\NS_DEF(builtins::web::performance)
        \\NS_DEF(builtins::web::timers)
        \\NS_DEF(builtins::web::worker_location)
        \\NS_DEF(builtins::web::text_codec)
        \\NS_DEF(builtins::web::streams)
        \\
    ;
    const builtins_incl_fetch =
        \\NS_DEF(builtins::web::fetch)
        \\NS_DEF(builtins::web::fetch::fetch_event)
        \\
    ;
    const builtins_incl_tail =
        \\NS_DEF(builtins::web::crypto)
        \\NS_DEF(builtins::wit_imports)
        \\
    ;
    const builtins_incl = if (prune_fetch_builtins)
        std.mem.concat(gpa, u8, &.{ builtins_incl_base, builtins_incl_tail }) catch @panic("OOM")
    else
        std.mem.concat(gpa, u8, &.{ builtins_incl_base, builtins_incl_fetch, builtins_incl_tail }) catch @panic("OOM");
    const wf = b.addWriteFiles();
    const builtins_incl_dir = wf.add("builtins.incl", builtins_incl).dirname();

    const ctx = Ctx{
        .b = b,
        .cxx_flags = cxx_flags.items,
        .c_flags = c_flags.items,
        .common_includes = &common_includes,
        .builtins_incl_dir = builtins_incl_dir,
        .host_api_dir = b.pathJoin(&.{ "host-apis", host_api_name }),
        .wasi020 = "host-apis/wasi-0.2.0",
        .wasi023 = "host-apis/wasi-0.2.3",
    };

    // ---- The final reactor executable ----
    // All StarlingMonkey C++ sources compile directly into the executable (not
    // archived), so the runtime's `export_name` entry points (wizer-initialize,
    // wizer.resume, cabi_realloc) are retained as GC roots and pull in the rest of
    // the program. Mirrors cmake `add_executable(starling-raw.wasm ${SOURCES})`.
    var generated_bindings: ?std.Build.LazyPath = null;
    var wasip3_dep: ?*std.Build.Dependency = null;
    if (dispatch_wit) |wit_dir| {
        const dep = b.dependency("wasip3", .{});
        wasip3_dep = dep;
        const bindgen = b.addRunArtifact(dep.artifact("wasip3-bindgen"));
        bindgen.addArg("--wit");
        addWitArg(b, bindgen, b.path(wit_dir));
        bindgen.addArgs(&.{ "--world", dispatch_world.?, "--dispatch", "js_dispatch", "--js-imports", "-o" });
        generated_bindings = bindgen.addOutputFileArg("component_bindings.zig");
    }

    const link_mod = b.createModule(.{
        .root_source_file = generated_bindings,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    if (wasip3_dep) |dep| {
        const wit_types = b.createModule(.{
            .root_source_file = dep.path("src/wit_types.zig"),
            .target = target,
            .optimize = optimize,
        });
        const js_dispatch = b.createModule(.{
            .root_source_file = b.path("runtime/js_dispatch.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // js_dispatch.zig needs the *same* `wit_types` module instance the
        // generated bindings use (below) so `wit_types.Char`/`ByteList`/
        // `Result(...)`/`Tuple(...)` type identity checks (`T == wit_types.Char`)
        // in js_dispatch.zig actually match the generated shell's types --
        // two separately-created modules pointing at the same source file
        // would otherwise compile as distinct, structurally-identical-but-
        // nominally-different types.
        js_dispatch.addImport("wit_types", wit_types);
        link_mod.addImport("wit_types", wit_types);
        link_mod.addImport("js_dispatch", js_dispatch);
    }
    const exe = b.addExecutable(.{ .name = "starling-raw", .root_module = link_mod });
    exe.wasi_exec_model = .reactor;
    exe.rdynamic = generated_bindings != null;
    // 1 MiB stack (cmake: -Wl,-z,stack-size=1048576). zig's wasm linker rejects
    // -Wl,--stack-first, so it is intentionally omitted.
    exe.stack_size = 1024 * 1024;
    addStarlingSources(ctx, link_mod);

    // Prebuilt component-type object for the selected host API.
    link_mod.addObjectFile(b.path(b.pathJoin(&.{ ctx.host_api_dir, "bindings/bindings_component_type.o" })));
    // OpenSSL libcrypto.a (cmake/openssl.cmake; linux-x32 installs to libx32/).
    link_mod.addObjectFile(b.path("deps/openssl-zig/libx32/libcrypto.a"));
    // Rust crate bundle (cmake/build-crates.cmake): encoding_mem_*, install_rust_hooks, url/multipart FFI.
    link_mod.addObjectFile(b.path("target/wasm32-wasip1/release/librust_staticlib.a"));
    // SpiderMonkey static lib (must be the Zig-built one; libc++ __1).
    link_mod.addObjectFile(b.path(sm_lib));

    // ---- Post-build: wasm-opt (port of the CMakeLists.txt USE_WASM_OPT block) ----
    var raw_wasm: std.Build.LazyPath = exe.getEmittedBin();
    if (use_wasm_opt and !is_debug) {
        if (b.lazyDependency("binaryen", .{})) |bin_dep| {
            const wo = std.Build.Step.Run.create(b, "wasm-opt");
            wo.addFileArg(bin_dep.path("bin/wasm-opt"));
            wo.addArgs(&.{
                "--strip-debug",                     "-O3",
                "--enable-bulk-memory",              "--enable-bulk-memory-opt",
                "--enable-sign-ext",                 "--enable-mutable-globals",
                "--enable-nontrapping-float-to-int", "--enable-multivalue",
                "--enable-reference-types",          "--enable-extended-const",
            });
            wo.addArg("-o");
            const opt_out = wo.addOutputFileArg("starling-raw.wasm");
            wo.addFileArg(exe.getEmittedBin());
            raw_wasm = opt_out;
        }
    }
    const install_raw = b.addInstallBinFile(raw_wasm, "starling-raw.wasm");
    b.getInstallStep().dependOn(&install_raw.step);

    // ---- Componentization tooling (port of componentize.sh.in + adapter copy) ----
    // Install the preview1 adapter and a generated componentize.sh next to
    // starling-raw.wasm so the runtime can be turned into a component.
    const adapter = b.pathJoin(&.{ ctx.wasi020, if (is_debug) "preview1-adapter-debug" else "preview1-adapter-release", "wasi_snapshot_preview1.wasm" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path(adapter), "preview1-adapter.wasm").step);
    if (component_wit) |wit_dir| {
        const install_wit = b.addInstallDirectory(.{
            .source_dir = b.path(wit_dir),
            .install_dir = .bin,
            .install_subdir = "component-wit",
            .include_extensions = &.{".wit"},
        });
        b.getInstallStep().dependOn(&install_wit.step);
    }

    // componentize.sh references the tools via `$(dirname "$0")/…`, so install them
    // alongside it (relocatable, mirrors the CMake build directory layout).
    if (b.lazyDependency("wasm-tools", .{})) |d|
        b.getInstallStep().dependOn(&b.addInstallBinFile(d.path("wasm-tools"), "wasm-tools").step);
    if (b.lazyDependency("wasmtime", .{})) |d|
        b.getInstallStep().dependOn(&b.addInstallBinFile(d.path("wasmtime"), "wasmtime").step);
    if (b.lazyDependency("weval", .{})) |d|
        b.getInstallStep().dependOn(&b.addInstallBinFile(d.path("weval"), "weval").step);

    const componentize_sh = renderComponentizeScript(b, component_world);
    const inst_componentize = b.addInstallBinFile(componentize_sh, "componentize.sh");
    b.getInstallStep().dependOn(&inst_componentize.step);
    // Installed generated files aren't executable; componentize.sh is invoked
    // directly (e.g. by tests/test.sh), so mark it +x after install.
    const installed_componentize = b.graph.path(.install_prefix, "bin/componentize.sh");
    const chmod = b.addSystemCommand(&.{ "chmod", "+x" });
    chmod.addFileArg(installed_componentize);
    chmod.step.dependOn(&inst_componentize.step);
    b.getInstallStep().dependOn(&chmod.step);

    // features.json: a machine-readable record of the resolved feature
    // selection for this build, installed next to componentize.sh/
    // starling-raw.wasm (cataggar/StarlingMonkey#6 Phase 6 diagnostics).
    // Consumed by tests/feature-selection/ to assert build-option ->
    // resolved-feature mapping without re-parsing build.zig, and useful for
    // humans inspecting `zig-out/bin/` to see what a given build selected.
    const features_json = b.fmt(
        \\{{
        \\  "stdio": {},
        \\  "random": {},
        \\  "clocks": {},
        \\  "http": {},
        \\  "fetch-event": {}
        \\}}
        \\
    , .{ features.stdio, features.random, features.clocks, features.http, features.fetch_event });
    const features_json_file = b.addWriteFiles().add("features.json", features_json);
    b.getInstallStep().dependOn(&b.addInstallBinFile(features_json_file, "features.json").step);

    // `zig build smoke-test`: componentize a trivial script and validate the
    // resulting component. Runs the *installed* componentize.sh so it finds
    // starling-raw.wasm, the adapter and the tools next to itself. (The full
    // multi-module e2e smoke.js needs the test harness's --strip-path-prefix and
    // is covered by the ported test suite, not this build step.)
    const smoke = b.step("smoke-test", "Componentize a trivial script and validate the component");
    const smoke_js = b.addWriteFiles().add("smoke.js", "addEventListener('fetch', e => e.respondWith(new Response('ok')));\nconsole.log('smoke ok');\n");
    b.getInstallStep().dependOn(&b.addInstallBinFile(smoke_js, "smoke.js").step);
    const installed_smoke_js = b.graph.path(.install_prefix, "bin/smoke.js");
    const smoke_out = b.graph.path(.install_prefix, "bin/smoke.wasm");
    const smoke_run = std.Build.Step.Run.create(b, "componentize smoke");
    smoke_run.addArg("bash");
    smoke_run.addFileArg(installed_componentize);
    smoke_run.addFileArg(installed_smoke_js);
    smoke_run.addArg("-o");
    smoke_run.addFileArg(smoke_out);
    smoke_run.step.dependOn(b.getInstallStep());
    if (b.lazyDependency("wasm-tools", .{})) |d| {
        const validate = std.Build.Step.Run.create(b, "validate smoke component");
        validate.addFileArg(d.path("wasm-tools"));
        validate.addArgs(&.{ "validate", "--features", "all" });
        validate.addFileArg(smoke_out);
        validate.step.dependOn(&smoke_run.step);
        smoke.dependOn(&validate.step);
    }

    // `zig build test`: run the e2e + integration suites (tests/run-suite.sh)
    // against the installed runtime in zig-out/bin.
    const test_step = b.step("test", "Run the e2e and integration test suites");
    // js_dispatch.zig's own unit tests need `wit_types` (for
    // `wit_types.Char`/`ByteList`/`Result`/`Tuple`) regardless of whether
    // this outer `zig build test` invocation itself set -Ddispatch-wit (it
    // normally doesn't -- see tests/e2e/native-dispatch/run.sh's own nested
    // build for that), so fetch the dependency directly here rather than
    // relying on the maybe-null `wasip3_dep` above.
    const wasip3_test_dep = b.dependency("wasip3", .{});
    const wit_types_test_mod = b.createModule(.{
        .root_source_file = wasip3_test_dep.path("src/wit_types.zig"),
        .target = b.graph.host,
    });
    const js_dispatch_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/js_dispatch.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    js_dispatch_test_mod.addImport("wit_types", wit_types_test_mod);
    const js_dispatch_tests = b.addTest(.{ .root_module = js_dispatch_test_mod });
    test_step.dependOn(&b.addRunArtifact(js_dispatch_tests).step);
    const heap_limit_tests = b.addSystemCommand(&.{ "bash", "tests/js-heap-limit/run.sh" });
    heap_limit_tests.addArg(b.graph.zig_exe);
    if (b.lazyDependency("wasmtime", .{})) |d|
        heap_limit_tests.addFileArg(d.path("wasmtime"));
    test_step.dependOn(&heap_limit_tests.step);
    const suite = b.addSystemCommand(&.{ "bash", "tests/run-suite.sh" });
    suite.addDirectoryArg(b.graph.path(.install_prefix, "bin"));
    suite.step.dependOn(b.getInstallStep());
    test_step.dependOn(&suite.step);

    // Typed native JS dispatch bridge E2E coverage: builds a dedicated
    // dispatch-enabled runtime, componentizes tests/fixtures/js-dispatch.js,
    // and drives it through `wasmtime run --invoke` (see
    // tests/e2e/native-dispatch/run.sh for the full case list: full-domain
    // i64/u64 boundaries, nested record+string, optional some/none,
    // list<u64>, wrong-type traps, and JSON-path regressions). This is a
    // separate nested `zig build install` (its own `-Dcomponent-world`), so
    // it doesn't depend on -- or get skipped by -- whatever component-world
    // flags the outer `zig build test` invocation itself used.
    const dispatch_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e/native-dispatch/run.sh" });
    dispatch_e2e.addArg(b.graph.zig_exe);
    test_step.dependOn(&dispatch_e2e.step);

    // `zig build compat-test`: Node-free, STRUCTURAL-ONLY ComponentizeJS
    // compatibility harness (tests/compat, cataggar/StarlingMonkey#6 Phase
    // 0). Unlike `test` above, this does not require the full wasm
    // build/install step: it validates tests/compat/manifest.json's
    // fixtures/WIT/expected outputs and schema structurally (plus a
    // best-effort optional Node self-check, skipped cleanly when Node is
    // absent). It does NOT build or run the real Zig/WABT bridge, and does
    // NOT execute anything through ComponentizeJS -- see
    // `compat-bridge-test` below for that, and tests/compat/README.md's
    // "Two harness modes" section for why these are kept distinct.
    const compat_test_step = b.step("compat-test", "Run the Node-free, structural-only ComponentizeJS compatibility harness (tests/compat)");
    const compat_run = b.addSystemCommand(&.{ "bash", "tests/compat/run-compat-tests.sh" });
    compat_test_step.dependOn(&compat_run.step);
    test_step.dependOn(compat_test_step);

    // `zig build compat-bridge-test`: the REQUIRED/FULL runtime
    // compatibility suite (tests/compat/runtime). Unlike `compat-test`
    // above, this actually builds the StarlingMonkey WIT dispatch reactor
    // for every tests/compat fixture, componentizes each with the real
    // Wizer+WABT pipeline, and invokes every export through Wasmtime,
    // comparing against tests/compat/manifest.json's checked-in
    // expectations -- see tests/compat/runtime/README.md. This is
    // deliberately NOT a dependency of `test`/`compat-test`: a full run
    // takes on the order of 15-20 minutes (a from-scratch Zig build per
    // fixture), and missing tools/artifacts (wasm-tools, a Rust toolchain,
    // the prebuilt SpiderMonkey/OpenSSL/Rust-staticlib artifacts this
    // build needs) make it fail outright rather than skip, so it must be
    // invoked explicitly as its own step.
    const compat_bridge_test_step = b.step("compat-bridge-test", "Run the real Zig/WABT/Wasmtime bridge compatibility suite (tests/compat/runtime; required/full, ~15-20 min, not part of `test`)");
    const compat_bridge_run = b.addSystemCommand(&.{ "bash", "tests/compat/runtime/run-bridge-tests.sh" });
    compat_bridge_test_step.dependOn(&compat_bridge_run.step);

    // `zig build feature-selection-test`: fast, Node-free unit/negative
    // tests for the feature-selection build options (cataggar/
    // StarlingMonkey#6 Phase 6; see docs/feature-selection/README.md).
    // Exercises build.zig's `-Dfeature-*`/`-Ddisable-features`/
    // `-Denable-features` parsing and deterministic `@panic` diagnostics
    // via `zig build --help` sub-invocations (which run the full build()`
    // validation logic without compiling anything), so this stays fast
    // enough to be part of `test` -- see
    // tests/feature-selection/run-build-option-tests.sh.
    const feature_selection_test_step = b.step("feature-selection-test", "Run the fast, Node-free feature-selection build-option unit/negative tests (tests/feature-selection)");
    const feature_selection_run = b.addSystemCommand(&.{ "bash", "tests/feature-selection/run-build-option-tests.sh" });
    feature_selection_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    feature_selection_test_step.dependOn(&feature_selection_run.step);

    // Fast, Node-free preprocessor/compile regression coverage for
    // include/feature-defaults.h (review follow-up: CMake and any
    // non-Zig compiler path left STARLING_FEATURE_* undefined, silently
    // compiling every gated feature as disabled). Proves, independent of
    // build.zig, that every macro defaults to 1 when undefined and that
    // explicit 0/1 definitions (as Zig always passes) remain authoritative
    // with no redefinition warnings -- see
    // tests/feature-selection/run-macro-default-tests.sh.
    const feature_selection_macro_run = b.addSystemCommand(&.{ "bash", "tests/feature-selection/run-macro-default-tests.sh" });
    feature_selection_macro_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    feature_selection_test_step.dependOn(&feature_selection_macro_run.step);
    test_step.dependOn(feature_selection_test_step);

    // `zig build feature-selection-runtime-test`: the REQUIRED/FULL
    // component-level feature-selection suite
    // (tests/feature-selection/run-runtime-tests.sh). Unlike
    // `feature-selection-test` above, this actually builds a full
    // StarlingMonkey runtime for each of 8 feature combinations,
    // componentizes representative fixtures, inspects the resulting
    // import/export surface with `wasm-tools component wit`, and invokes
    // representative behavior through `wasmtime serve` -- see
    // docs/feature-selection/README.md. Deliberately NOT a dependency of
    // `test`/`feature-selection-test`: each combination is a from-scratch
    // Zig build, so a full run takes several minutes, matching the
    // `compat-bridge-test` precedent of keeping slow, real-build
    // verification in its own opt-in step.
    const feature_selection_runtime_test_step = b.step("feature-selection-runtime-test", "Run the real, full-build feature-selection component tests (tests/feature-selection; required/full, not part of `test`)");
    const feature_selection_runtime_run = b.addSystemCommand(&.{ "bash", "tests/feature-selection/run-runtime-tests.sh" });
    feature_selection_runtime_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    feature_selection_runtime_test_step.dependOn(&feature_selection_runtime_run.step);
    // `zig build wit-imports-e2e-test`: the "wit-imports" roadmap phase's E2E
    // suite (tests/e2e/wit-imports). Builds a dedicated dispatch-enabled
    // reactor against a fixture-specific WIT world that additionally
    // *imports* a custom `test:wit-imports/host@1.2.3` interface (not just
    // the usual export-only js-dispatch world), componentizes
    // tests/e2e/wit-imports/component.js against it (a JS module that
    // `import`s host functions with zero user-written glue), and drives
    // every export through a Wasmtime 42 host that implements the custom
    // import dynamically (tests/compat/runtime/invoker's
    // `wit-imports-invoker` binary, since `wasmtime run --invoke` cannot
    // supply arbitrary custom component imports). Exercises exact s64/u64
    // BigInt (including 2**64 wraparound), strings, nested records bridged
    // across independently-declared WIT types, repeated calls to the same
    // import, real host-trap propagation, and -- by re-instantiating with
    // the host import deliberately omitted -- Wasmtime's own actionable
    // "missing import" diagnostic. Also exercises every other synchronous
    // type the native bridge supports (char/option<char>, list<u8> bytes
    // including a nested/optional case, tuple, enum/option<enum>,
    // flags/option<flags>, variant with void and payload cases, and
    // result<T,E> both-payload and void-ok-payload forms), each through a
    // real host-side transform, now that cataggar/wabt PR #335 (see
    // build.zig.zon's `.wasip3` pin) fixed the reverse (`--js-imports`)
    // bridge's type gate and lowering for all of them. Like `compat-bridge-test`, this is
    // deliberately NOT part of `test`: it requires a Rust toolchain and
    // takes on the order of several minutes end to end (fresh Zig build +
    // Cranelift compilation under load), so it must be invoked explicitly.
    const wit_imports_e2e_test_step = b.step("wit-imports-e2e-test", "Run the WIT interface-imports E2E suite (tests/e2e/wit-imports; requires Rust, not part of `test`)");
    const wit_imports_e2e_run = b.addSystemCommand(&.{ "bash", "tests/e2e/wit-imports/run.sh" });
    wit_imports_e2e_run.addArg(b.graph.zig_exe);
    wit_imports_e2e_test_step.dependOn(&wit_imports_e2e_run.step);

    // ---- Objects-only verification step ----
    // A static archive that compiles the full C++ tree without resolving the
    // SpiderMonkey/Rust/OpenSSL externals.
    const cc_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    const cc_lib = b.addLibrary(.{ .name = "starling_cc", .root_module = cc_mod, .linkage = .static });
    addStarlingSources(ctx, cc_mod);
    const cc_step = b.step("cc", "Compile the StarlingMonkey C++ sources (objects only)");
    cc_step.dependOn(&cc_lib.step);

    // ---- EXPERIMENT (world-shell-spike): does the full engine link as a PIC
    // wasm32-wasi dynamic library (dylink.0), so it can later be composed with a
    // thin WIT-specific shell via `wasm-tools component link` instead of a full
    // monolithic relink? Gated behind -Dengine-dylib-experiment so it never runs
    // by default (default build/test behavior is unaffected either way).
    //
    // Status: this step builds successfully. deps/openssl-zig/libx32/libcrypto.a,
    // target/wasm32-wasip1/release/librust_staticlib.a, and the SpiderMonkey
    // object archive are now all real, PIC (-fPIC) artifacts (see
    // docs/pic-rust/, deps/verify-openssl-pic.sh, docs/pic-spidermonkey/), so
    // this closes the original blocker documented in docs/world-shell-spike.md
    // (17253 link errors from non-PIC OpenSSL/Rust archives). The engine links
    // as a valid `dylink.0`-tagged PIC dylib, world-independent (no
    // component/dispatch WIT compiled in), and composes cleanly with a thin
    // per-world shell via `wasm-tools component link` -- see
    // docs/world-shell-integration/README.md.
    //
    // What remains blocked is initializing that composed engine+shell as a
    // reusable JS-engine snapshot: Wizer refuses any module that imports
    // memory ("imported memories are not supported"), and every
    // `-dynamic -fPIC` wasm32-wasi dylib produced by this wasm-ld imports its
    // memory rather than owning/exporting it (there is no flag combination
    // that produces a `-shared`/`dylink.0` module which owns memory instead).
    // This is a structural Wizer/imported-memory constraint of the pinned
    // toolchain, not a StarlingMonkey PIC-linkage problem -- see
    // docs/world-shell-integration/README.md for the exact reproducible
    // probes.
    // Run with: zig build engine-dylib-experiment -Dengine-dylib-experiment=true
    if (b.option(bool, "engine-dylib-experiment", "world-shell-spike: build the engine as a PIC dylib") orelse false) {
        const engine_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        });
        const engine_lib = b.addLibrary(.{ .name = "starling-engine", .root_module = engine_mod, .linkage = .dynamic });
        addStarlingSources(ctx, engine_mod);
        engine_mod.addObjectFile(b.path(b.pathJoin(&.{ ctx.host_api_dir, "bindings/bindings_component_type.o" })));
        engine_mod.addObjectFile(b.path("deps/openssl-zig/libx32/libcrypto.a"));
        engine_mod.addObjectFile(b.path("target/wasm32-wasip1/release/librust_staticlib.a"));
        engine_mod.addObjectFile(b.path(sm_lib));
        const engine_step = b.step("engine-dylib-experiment", "world-shell-spike: link the engine as a PIC dylib");
        const inst_engine = b.addInstallBinFile(engine_lib.getEmittedBin(), "starling-engine.wasm");
        inst_engine.step.dependOn(&engine_lib.step);
        engine_step.dependOn(&inst_engine.step);
    }

    // ---- EXPERIMENT (world-shell-integration): thin, WIT-specific "shell" PIC
    // dylib -- only the generated component bindings + the typed js_dispatch
    // bridge (Zig side), *not* any StarlingMonkey C++/SpiderMonkey/OpenSSL/Rust
    // sources. `starling_js_dispatch`/`starling_js_dispatch_native`/
    // `starling_js_dispatch_native_free`/`cabi_realloc` are left as unresolved
    // externs, to be satisfied at composition time (`wasm-tools component link`)
    // by the engine dylib's own exports of those same symbols. Requires
    // -Ddispatch-wit/-Ddispatch-world (same flags the monolithic path already
    // uses to select a WIT world). Gated behind -Dshell-dylib-experiment so it
    // never runs by default.
    if (b.option(bool, "shell-dylib-experiment", "world-shell-integration: build a thin WIT shell as a PIC dylib") orelse false) {
        if (wasip3_dep == null) @panic("-Dshell-dylib-experiment requires -Ddispatch-wit/-Ddispatch-world");
        const dep = wasip3_dep.?;
        // link_libc intentionally omitted: linking wasi-libc into *both* the
        // engine and this shell dylib makes each pull in its own copy of
        // libc's internal weak helper symbols (e.g.
        // `__wasilibc_find_relpath_alloc`), which `wasm-tools component link`
        // rejects as a duplicate export across side modules (composing two
        // -dynamic -fPIC modules that both statically link libc is not
        // supported by the installed wasm-tools 1.250.0 -- see
        // docs/world-shell-integration/README.md). The shell has no need for
        // its own libc: all allocation goes through the engine's exported
        // `cabi_realloc`, and `free`/`malloc`, if referenced, resolve as
        // cross-module imports against the engine's own libc instead.
        const shell_mod = b.createModule(.{
            .root_source_file = generated_bindings,
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        const wit_types = b.createModule(.{
            .root_source_file = dep.path("src/wit_types.zig"),
            .target = target,
            .optimize = optimize,
        });
        const js_dispatch = b.createModule(.{
            .root_source_file = b.path("runtime/js_dispatch.zig"),
            .target = target,
            .optimize = optimize,
        });
        shell_mod.addImport("wit_types", wit_types);
        js_dispatch.addImport("wit_types", wit_types);
        shell_mod.addImport("js_dispatch", js_dispatch);
        const shell_lib = b.addLibrary(.{ .name = "starling-shell", .root_module = shell_mod, .linkage = .dynamic });
        const shell_step = b.step("shell-dylib-experiment", "world-shell-integration: link a thin WIT shell as a PIC dylib");
        const inst_shell = b.addInstallBinFile(shell_lib.getEmittedBin(), "starling-shell.wasm");
        inst_shell.step.dependOn(&shell_lib.step);
        shell_step.dependOn(&inst_shell.step);
    }
}

// Render componentize.sh from componentize.sh.in, pointing the tool paths at the
// binaries installed next to it (resolved at runtime via `$(dirname "$0")`).
fn renderComponentizeScript(b: *std.Build, component_world: ?[]const u8) std.Build.LazyPath {
    const template = @embedFile("componentize.sh.in");
    var buf = std.ArrayList(u8).empty;
    const gpa = b.allocator;
    var rest: []const u8 = template;
    const subs = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "@WASMTIME_DIR@", .to = "$(dirname \"$0\")" },
        .{ .from = "@WASM_TOOLS_BIN@", .to = "$(dirname \"$0\")/wasm-tools" },
        .{ .from = "@WEVAL_BIN@", .to = "$(dirname \"$0\")/weval" },
        .{ .from = "@AOT@", .to = "0" },
        .{ .from = "@COMPONENT_WORLD@", .to = component_world orelse "" },
        .{ .from = "@COMPONENT_WIT_DIR@", .to = "$(dirname \"$0\")/component-wit" },
    };
    outer: while (rest.len != 0) {
        for (subs) |s| {
            if (std.mem.startsWith(u8, rest, s.from)) {
                buf.appendSlice(gpa, s.to) catch @panic("OOM");
                rest = rest[s.from.len..];
                continue :outer;
            }
        }
        buf.append(gpa, rest[0]) catch @panic("OOM");
        rest = rest[1..];
    }
    const wf = b.addWriteFiles();
    return wf.add("componentize.sh", buf.items);
}

fn addWitArg(b: *std.Build, cmd: *std.Build.Step.Run, wit: std.Build.LazyPath) void {
    cmd.addDirectoryArg(wit);
    const sp = switch (wit) {
        .src_path => |source| source,
        else => return,
    };
    const io = b.graph.io;
    const path = sp.owner.root.join(b.allocator, sp.sub_path) catch |err|
        std.process.fatal("failed to resolve WIT directory '{s}': {t}", .{ sp.sub_path, err });
    var dir = path.root_dir.handle.openDir(
        io,
        path.sub_path,
        .{ .iterate = true },
    ) catch |err| std.process.fatal("failed to open WIT directory '{s}': {t}", .{ sp.sub_path, err });
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch |err|
        std.process.fatal("failed to walk WIT directory '{s}': {t}", .{ sp.sub_path, err });
    defer walker.deinit();
    while (walker.next(io) catch |err|
        std.process.fatal("failed to read WIT directory '{s}': {t}", .{ sp.sub_path, err })) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wit")) continue;
        cmd.addFileInput(wit.path(b, entry.path));
    }
}

fn addStarlingSources(ctx: Ctx, mod: *std.Build.Module) void {
    const b = ctx.b;
    for (ctx.common_includes) |d| mod.addIncludePath(b.path(d));
    mod.addIncludePath(ctx.builtins_incl_dir);
    mod.addIncludePath(b.path("crates/rust-url"));
    mod.addIncludePath(b.path("crates/rust-multipart"));
    mod.addIncludePath(b.path("deps/openssl-zig/include"));

    // runtime sources (cmake top-level SOURCES).
    mod.addCSourceFiles(.{ .files = &runtime_sources, .flags = ctx.cxx_flags, .language = .cpp });
    // builtins install dispatcher + all default-enabled builtins.
    mod.addCSourceFile(.{ .file = b.path("builtins/install_builtins.cpp"), .flags = ctx.cxx_flags, .language = .cpp });
    mod.addCSourceFiles(.{ .files = &builtin_sources, .flags = ctx.cxx_flags, .language = .cpp });

    // rust-hooks C++ support file (cmake target rust-hooks-wrappers): provides RustMozCrash.
    mod.addCSourceFile(.{ .file = b.path("crates/rust-hooks/src/wrappers.cpp"), .flags = ctx.cxx_flags, .language = .cpp });

    // host_api (port of host-apis/<name>/host_api.cmake for wasi-0.2.x).
    mod.addIncludePath(b.path(b.pathJoin(&.{ ctx.wasi020, "include" })));
    mod.addIncludePath(b.path(b.pathJoin(&.{ ctx.wasi023, "include" })));
    mod.addIncludePath(b.path(ctx.wasi020));
    mod.addIncludePath(b.path(b.pathJoin(&.{ ctx.host_api_dir, "include" })));
    mod.addCSourceFiles(.{ .files = &.{
        b.pathJoin(&.{ ctx.wasi020, "host_api.cpp" }),
        b.pathJoin(&.{ ctx.wasi020, "host_call.cpp" }),
        b.pathJoin(&.{ ctx.wasi023, "sockets.cpp" }),
    }, .flags = ctx.cxx_flags, .language = .cpp });
    mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ ctx.host_api_dir, "bindings/bindings.c" })), .flags = ctx.c_flags, .language = .c });

    // Preview1-level feature stubs (cataggar/StarlingMonkey#6 Phase 6): a
    // plain C source overriding the low-level `__imported_wasi_snapshot_
    // preview1_*` import trampolines that wasi-libc's auto-generated
    // __wasilibc_real.c declares (see docs/feature-selection/README.md
    // "preview1-level stubbing" for why this is done at the C symbol level
    // rather than by post-processing the compiled wasm module: it lets the
    // normal clang/wasm-ld toolchain assign function indices, avoiding the
    // index-corruption risk of hand-editing a stripped/unnamed WAT dump).
    // Included unconditionally; each override is itself `#if
    // !STARLING_FEATURE_*`-gated, so when a feature is enabled this file
    // contributes no symbols and the normal WASI import is left untouched.
    mod.addCSourceFile(.{ .file = b.path("runtime/feature_stubs.c"), .flags = ctx.c_flags, .language = .c });
}

const runtime_sources = [_][]const u8{
    "runtime/js.cpp",
    "runtime/allocator.cpp",
    "runtime/encode.cpp",
    "runtime/decode.cpp",
    "runtime/engine.cpp",
    "runtime/event_loop.cpp",
    "runtime/js_dispatch.cpp",
    "runtime/builtin.cpp",
    "runtime/script_loader.cpp",
    "runtime/debugger.cpp",
};

const builtin_sources = [_][]const u8{
    "builtins/web/global_self.cpp",
    "builtins/web/queue-microtask.cpp",
    "builtins/web/structured-clone.cpp",
    "builtins/web/base64.cpp",
    "builtins/web/blob.cpp",
    "builtins/web/file.cpp",
    "builtins/web/console.cpp",
    "builtins/web/performance.cpp",
    "builtins/web/worker-location.cpp",
    "builtins/web/dom-exception.cpp",
    "builtins/web/url.cpp",
    "builtins/web/timers.cpp",
    "builtins/web/event/event.cpp",
    "builtins/web/event/event-target.cpp",
    "builtins/web/event/custom-event.cpp",
    "builtins/web/event/global-event-target.cpp",
    "builtins/web/abort/abort-signal.cpp",
    "builtins/web/abort/abort-controller.cpp",
    "builtins/web/form-data/form-data.cpp",
    "builtins/web/form-data/form-data-encoder.cpp",
    "builtins/web/form-data/form-data-parser.cpp",
    "builtins/web/text-codec/text-codec.cpp",
    "builtins/web/text-codec/text-decoder.cpp",
    "builtins/web/text-codec/text-encoder.cpp",
    "builtins/web/streams/buf-reader.cpp",
    "builtins/web/streams/compression-stream.cpp",
    "builtins/web/streams/decompression-stream.cpp",
    "builtins/web/streams/native-stream-sink.cpp",
    "builtins/web/streams/native-stream-source.cpp",
    "builtins/web/streams/streams.cpp",
    "builtins/web/streams/transform-stream.cpp",
    "builtins/web/streams/transform-stream-default-controller.cpp",
    "builtins/web/fetch/fetch-api.cpp",
    "builtins/web/fetch/fetch-utils.cpp",
    "builtins/web/fetch/headers.cpp",
    "builtins/web/fetch/request-response.cpp",
    "builtins/web/fetch/fetch_event.cpp",
    "builtins/web/crypto/crypto.cpp",
    "builtins/web/crypto/crypto-algorithm.cpp",
    "builtins/web/crypto/crypto-key.cpp",
    "builtins/web/crypto/crypto-key-ec-components.cpp",
    "builtins/web/crypto/crypto-key-rsa-components.cpp",
    "builtins/web/crypto/json-web-key.cpp",
    "builtins/web/crypto/subtle-crypto.cpp",
    "builtins/web/crypto/uuid.cpp",
};
