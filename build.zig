const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = "0.17.0-dev.902+7255f3e72";

const RuntimeBuildTool = struct {
    name: []const u8,
    executable: std.Build.LazyPath,
};


fn dependencyExecutable(
    dependency: *std.Build.Dependency,
    name: []const u8,
) *std.Build.Step.Compile {
    for (dependency.builder.install_tls.step.dependencies.items) |step| {
        const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (install.artifact.kind == .exe and std.mem.eql(u8, install.artifact.name, name))
            return install.artifact;
    }
    @panic("dependency executable not found");
}

fn inputPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path))
        .{ .cwd_relative = path }
    else
        b.path(path);
fn addPrefixBinFile(
    b: *std.Build,
    generation: ?*std.Build.Step.WriteFile,
    source: std.Build.LazyPath,
    name: []const u8,
) *std.Build.Step {
    if (generation) |private| {
        _ = private.addCopyFile(
            source,
            b.fmt("bin/{s}", .{name}),
        );
        return &private.step;
    }
    const install = b.addInstallBinFile(source, name);
    b.getInstallStep().dependOn(&install.step);
    return &install.step;
}

fn addPrefixBinDirectory(
    b: *std.Build,
    generation: ?*std.Build.Step.WriteFile,
    source: std.Build.LazyPath,
    name: []const u8,
    include_extensions: ?[]const []const u8,
) *std.Build.Step {
    if (generation) |private| {
        _ = private.addCopyDirectory(
            source,
            b.fmt("bin/{s}", .{name}),
            .{ .include_extensions = include_extensions },
        );
        return &private.step;
    }
    const install = b.addInstallDirectory(.{
        .source_dir = source,
        .install_dir = .bin,
        .install_subdir = name,
        .include_extensions = include_extensions,
    });
    b.getInstallStep().dependOn(&install.step);
    return &install.step;
}

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
// (see docs/feature-selection/README.md for the full behavior matrix), but is
// threaded through typed Zig build options
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
// docs/feature-selection/README.md), which this build
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
    if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
        std.debug.print(
            "error: StarlingMonkey requires Zig {s}; found {s}\n",
            "error: StarlingMonkey v0.4 requires Zig {s}; found {s}\n",
            .{ required_zig_version, builtin.zig_version_string },
        );
        @panic("unsupported Zig version");
    }
    const optimize = b.standardOptimizeOption(.{});
    const host_api_selection = b.option(
        []const u8,
        "host-api",
        "Host API name under host-apis/ or a repository-relative implementation path",
    ) orelse "wasi-0.2.10";
    const host_api_dir = if (std.mem.indexOfScalar(u8, host_api_selection, '/') != null)
        host_api_selection
    else
        b.pathJoin(&.{ "host-apis", host_api_selection });
    const host_api_identity = std.fs.path.basename(host_api_dir);
    const host_api_world = b.option(
        []const u8,
        "host-api-world",
        "Default component world in the selected host API WIT package",
    ) orelse "bindings";
    const aot_engine = b.option(
        bool,
        "aot-engine",
        "Build the PBL+Weval SpiderMonkey variant and its sealed IC cache",
    ) orelse false;
    const aot_generation = if (aot_engine) b.addWriteFiles() else null;
    var aot_generation_chmod: ?*std.Build.Step.Run = null;

    // Native, Node-free driver for the monolithic Zig/WABT componentization
    // pipeline. It is a host tool even though the runtime it builds targets
    // wasm32-wasi.
    const componentizer_options = b.addOptions();
    componentizer_options.addOption([]const u8, "version", "0.4.1");
    componentizer_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    componentizer_options.addOption([]const u8, "host_api", host_api_selection);
    componentizer_options.addOption([]const u8, "host_api_world", host_api_world);
    const componentizer_mod = b.createModule(.{
        .root_source_file = b.path("tools/componentizer/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const feature_surface_lib = b.createModule(.{
        .root_source_file = b.path("tools/feature-surface/surface.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    componentizer_mod.addImport("feature_surface", feature_surface_lib);
    componentizer_mod.addOptions("build_options", componentizer_options);
    const componentizer = b.addExecutable(.{
        .name = "starling-componentize",
        .root_module = componentizer_mod,
    });
    b.installArtifact(componentizer);
    const feature_surface_mod = b.createModule(.{
        .root_source_file = b.path("tools/feature-surface/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const feature_surface = b.addExecutable(.{
        .name = "starling-feature-surface",
        .root_module = feature_surface_mod,
    });
    b.installArtifact(feature_surface);
    _ = addPrefixBinFile(
        b,
        aot_generation,
        componentizer.getEmittedBin(),
        "starling-componentize",
    );
    const aot_cache_tool = b.addExecutable(.{
        .name = "starling-aot-cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/componentizer/aot_cache_seal.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    _ = addPrefixBinFile(
        b,
        aot_generation,
        aot_cache_tool.getEmittedBin(),
        "starling-aot-cache",
    );
    const wabt = dependencyExecutable(b.dependency("wabt", .{}), "wabt");
    const install_wabt = b.addInstallArtifact(wabt, .{});
    b.getInstallStep().dependOn(&install_wabt.step);
    const wabt_step = b.step("wabt", "Build and install the pinned WABT CLI");
    wabt_step.dependOn(&install_wabt.step);
    _ = addPrefixBinFile(
        b,
        aot_generation,
        wabt.getEmittedBin(),
        "wabt",
    );
    const componentizer_step = b.step(
        "componentizer",
        "Build the native starling-componentize CLI",
    );
    componentizer_step.dependOn(&componentizer.step);
    componentizer_step.dependOn(&feature_surface.step);
    const componentizer_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/componentizer/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    componentizer_test_mod.addOptions("build_options", componentizer_options);
    componentizer_test_mod.addImport("feature_surface", feature_surface_lib);
    const componentizer_tests = b.addTest(.{ .root_module = componentizer_test_mod });
    const run_componentizer_tests = b.addRunArtifact(componentizer_tests);
    const componentizer_metadata_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/componentizer/metadata.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const componentizer_metadata_tests = b.addTest(.{
        .root_module = componentizer_metadata_test_mod,
    });
    const run_componentizer_metadata_tests = b.addRunArtifact(
        componentizer_metadata_tests,
    );
    const feature_surface_tests = b.addTest(.{ .root_module = feature_surface_mod });
    const run_feature_surface_tests = b.addRunArtifact(feature_surface_tests);
    const componentizer_test_step = b.step(
        "componentizer-test",
        "Run native componentizer unit and fake-tool orchestration tests",
    );
    componentizer_test_step.dependOn(&run_componentizer_tests.step);
    componentizer_test_step.dependOn(&run_componentizer_metadata_tests.step);
    componentizer_test_step.dependOn(&run_feature_surface_tests.step);
    const aot_package_test_step = b.step(
        "aot-package-test",
        "Race two validated AOT bundles through release publication",
    );
    const aot_package_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-package-aot.sh" },
    );
    aot_package_test.addArtifactArg(aot_cache_tool);
    aot_package_test.addFileArg(b.path("scripts/package-aot-release.sh"));
    aot_package_test_step.dependOn(&aot_package_test.step);
    componentizer_test_step.dependOn(aot_package_test_step);
    const aot_seal_alias_test_step = b.step(
        "aot-seal-alias-test",
        "Reject all AOT seal input/output filesystem aliases",
    );
    const aot_seal_alias_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-seal-aliases.sh" },
    );
    aot_seal_alias_test.addArtifactArg(aot_cache_tool);
    aot_seal_alias_test_step.dependOn(&aot_seal_alias_test.step);
    componentizer_test_step.dependOn(aot_seal_alias_test_step);
    const aot_seal_transaction_test_step = b.step(
        "aot-seal-transaction-test",
        "Race descriptor-anchored AOT seal publication and rollback",
    );
    const aot_seal_transaction_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-seal-transactions.sh" },
    );
    aot_seal_transaction_test.addArtifactArg(aot_cache_tool);
    aot_seal_transaction_test_step.dependOn(&aot_seal_transaction_test.step);
    componentizer_test_step.dependOn(aot_seal_transaction_test_step);
    const aot_shell_test_step = b.step(
        "aot-shell-test",
        "Test AOT shell tool resolution and recursive Zig forwarding",
    );
    const aot_shell_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-aot-shell-regressions.sh" },
    );
    aot_shell_test_step.dependOn(&aot_shell_test.step);
    componentizer_test_step.dependOn(aot_shell_test_step);
    const archive_test = b.addSystemCommand(
        &.{ "bash", "deps/test-spidermonkey-archive.sh" },
    );
    archive_test.addArg(b.graph.zig_exe);
    componentizer_test_step.dependOn(&archive_test.step);
    const release_inventory_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-release-inventory.sh" },
    );
    release_inventory_test.addFileArg(
        b.path("scripts/check-release-artifacts.sh"),
    );
    componentizer_test_step.dependOn(&release_inventory_test.step);
    const zig_version_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-zig-version.sh" },
    );
    zig_version_test.addFileArg(b.path("scripts/require-zig-version.sh"));
    zig_version_test.addArg(b.graph.zig_exe);
    componentizer_test_step.dependOn(&zig_version_test.step);
    const componentizer_orchestration = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run.sh" },
    );
    componentizer_orchestration.addArtifactArg(componentizer);
    componentizer_orchestration.addArg(host_api_selection);
    componentizer_orchestration.addArtifactArg(aot_cache_tool);
    if (b.lazyDependency("wasm-tools", .{})) |dep|
        componentizer_orchestration.addFileArg(dep.path("wasm-tools"));
    componentizer_test_step.dependOn(&componentizer_orchestration.step);
    const absolute_wit_inputs = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-absolute-wit.sh" },
    );
    absolute_wit_inputs.addArg(b.graph.zig_exe);
    componentizer_test_step.dependOn(&absolute_wit_inputs.step);
    const componentizer_e2e_step = b.step(
        "componentizer-e2e-test",
        "Run the real cached monolithic native componentizer E2E",
    );
    const componentizer_e2e = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-real.sh" },
    );
    componentizer_e2e.addArtifactArg(componentizer);
    componentizer_e2e.addArg(b.graph.zig_exe);
    if (b.lazyDependency("wasmtime", .{})) |dep| {
        componentizer_e2e.addFileArg(dep.path("wasmtime"));
    }
    if (b.lazyDependency("wasm-tools", .{})) |dep| {
        componentizer_e2e.addFileArg(dep.path("wasm-tools"));
    }
    componentizer_e2e.addArtifactArg(wabt);
    componentizer_e2e.addFileArg(
        b.path(b.pathJoin(&.{
            host_api_dir,
            "preview1-adapter-release",
            "wasi_snapshot_preview1.wasm",
        })),
    );
    componentizer_e2e.addArg(host_api_identity);
    componentizer_e2e_step.dependOn(&componentizer_e2e.step);
    componentizer_test_step.dependOn(componentizer_e2e_step);
    const aot_engine_test_step = b.step(
        "aot-engine-test",
        "Build Wizer/AOT variants and prove component behavior is equivalent",
    );
    const aot_engine_test = b.addSystemCommand(
        &.{ "bash", "tests/componentizer/run-aot.sh" },
    );
    aot_engine_test.addArtifactArg(componentizer);
    aot_engine_test.addArg(b.graph.zig_exe);
    if (b.lazyDependency("wasmtime", .{})) |dep| {
        aot_engine_test.addFileArg(dep.path("wasmtime"));
    }
    if (b.lazyDependency("wasm-tools", .{})) |dep| {
        aot_engine_test.addFileArg(dep.path("wasm-tools"));
    }
    aot_engine_test.addArtifactArg(wabt);
    aot_engine_test.addFileArg(
        b.path("host-apis/wasi-0.2.0/preview1-adapter-release/wasi_snapshot_preview1.wasm"),
    );
    if (b.lazyDependency("weval", .{})) |dep| {
        aot_engine_test.addFileArg(dep.path("weval"));
    }
    aot_engine_test.addArtifactArg(aot_cache_tool);
    aot_engine_test_step.dependOn(&aot_engine_test.step);

    // StarlingMonkey only targets wasm32-wasi (reactor).
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    const enable_debugger = b.option(bool, "debugger", "Enable JS debugger socket support") orelse true;
    const use_wasm_opt = b.option(bool, "wasm-opt", "Optimize starling-raw.wasm with wasm-opt for release builds") orelse true;
    const preview1_adapter = b.option([]const u8, "preview1-adapter", "Retained preview1 adapter supplied by the componentizer");
    const host_api_name = b.option([]const u8, "host-api", "Host API implementation under host-apis/") orelse "wasi-0.2.10";
    const requested_wasm_opt = b.option(bool, "wasm-opt", "Optimize starling-raw.wasm with wasm-opt for release builds");
    const use_wasm_opt = requested_wasm_opt orelse !aot_engine;
    if (aot_engine and use_wasm_opt) {
        @panic("-Daot-engine requires -Dwasm-opt=false (the default for AOT builds)");
    }
    const component_wit = b.option([]const u8, "component-wit", "WIT directory whose exported functions dispatch to JavaScript");
    const component_world = b.option([]const u8, "component-world", "World to generate JavaScript-backed exports for");
    if ((component_wit == null) != (component_world == null)) {
        @panic("-Dcomponent-wit and -Dcomponent-world must be provided together");
    }
    const dispatch_wit = b.option([]const u8, "dispatch-wit", "Export-only WIT directory used to generate JavaScript dispatch bindings") orelse component_wit;
    const dispatch_world = b.option([]const u8, "dispatch-world", "Export-only world used to generate JavaScript dispatch bindings") orelse component_world;
    const componentizer_debug_bindings = b.option(
        bool,
        "componentizer-debug-bindings",
        "Install generated dispatch bindings for native componentizer debug output",
    ) orelse false;
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
    const feature_abi = b.fmt(
        "starling-features-v1;stdio={d};random={d};clocks={d};http={d};" ++
            "fetch-event={d};optimize={s};host-api={s};debugger={d}",
        .{
            @intFromBool(features.stdio),
            @intFromBool(features.random),
            @intFromBool(features.clocks),
            @intFromBool(features.http),
            @intFromBool(features.fetch_event),
            @tagName(optimize),
            host_api_name,
            @intFromBool(enable_debugger),
        },
    );

    // SpiderMonkey artifacts built from source with Zig (see deps/mozconfig-zig).
    const sm_dist = if (aot_engine)
        b.option([]const u8, "spidermonkey-aot-dist", "Path to an explicitly AOT-enabled Zig-built SpiderMonkey dist dir") orelse "deps/sm-obj-zig-aot/dist"
    else
        b.option([]const u8, "spidermonkey-dist", "Path to the Zig-built SpiderMonkey dist dir") orelse "deps/sm-obj-zig/dist";
    const sm_confdefs = if (aot_engine)
        b.option([]const u8, "spidermonkey-aot-confdefs", "Path to the explicitly AOT-enabled js-confdefs.h") orelse "deps/sm-obj-zig-aot/js/src/js-confdefs.h"
    else
        b.option([]const u8, "spidermonkey-confdefs", "Path to js-confdefs.h") orelse "deps/sm-obj-zig/js/src/js-confdefs.h";
    const sm_include = b.pathJoin(&.{ sm_dist, "include" });
    const sm_lib = b.pathJoin(&.{ sm_dist, "libspidermonkey.a" });

    const is_debug = optimize == .Debug;
    const gpa = b.allocator;
    var runtime_build_tools: std.ArrayList(RuntimeBuildTool) = .empty;

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
    // failing only at the WASI-import call site).
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
        .host_api_dir = host_api_dir,
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
    const wit_bindgen_step = b.step(
        "wit-bindgen",
        "Generate dispatch bindings without building the runtime",
    );
    if (dispatch_wit) |wit_dir| {
        const dep = b.dependency("wasip3", .{});
        wasip3_dep = dep;
        const bindgen_artifact = dep.artifact("wasip3-bindgen");
        bindgen_artifact.root_module.optimize = .ReleaseSmall;
        const bindgen_snapshot = b.addWriteFiles().addCopyFile(
            bindgen_artifact.getEmittedBin(),
            "wasip3-bindgen",
        );
        runtime_build_tools.append(gpa, .{
            .name = "wasip3-bindgen",
            .executable = bindgen_snapshot,
        }) catch @panic("OOM");
        const bindgen = std.Build.Step.Run.create(b, "wasip3-bindgen");
        bindgen.addFileArg(bindgen_snapshot);
        bindgen.addArg("--wit");
        addWitArg(b, bindgen, inputPath(b, wit_dir));
        bindgen.addArgs(&.{ "--world", dispatch_world.?, "--dispatch", "js_dispatch", "--js-imports", "-o" });
        generated_bindings = bindgen.addOutputFileArg("component_bindings.zig");
        const install_bindings = b.addInstallFile(
            generated_bindings.?,
            "wit-bindgen/component_bindings.zig",
        );
        wit_bindgen_step.dependOn(&install_bindings.step);
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
    if (componentizer_debug_bindings) {
        if (generated_bindings) |bindings| {
            _ = addPrefixBinFile(
                b,
                aot_generation,
                bindings,
                "component-bindings.zig",
            );
        }
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
            const wasm_opt_snapshot = b.addWriteFiles().addCopyFile(
                bin_dep.path("bin/wasm-opt"),
                "wasm-opt",
            );
            runtime_build_tools.append(gpa, .{
                .name = "wasm-opt",
                .executable = wasm_opt_snapshot,
            }) catch @panic("OOM");
            const wo = std.Build.Step.Run.create(b, "wasm-opt");
            wo.addFileArg(wasm_opt_snapshot);
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
    const feature_tuple = b.fmt(
        "{d}{d}{d}{d}{d}",
        .{
            @intFromBool(features.stdio),
            @intFromBool(features.random),
            @intFromBool(features.clocks),
            @intFromBool(features.http),
            @intFromBool(features.fetch_event),
        },
    );
    const provenance = b.addSystemCommand(&.{"python3"});
    provenance.addFileArg(b.path("tools/embed-engine-provenance.py"));
    provenance.addFileArg(raw_wasm);
    const provenanced_raw = provenance.addOutputFileArg("starling-raw.wasm");
    provenance.addArgs(&.{
        host_api_identity,
        feature_tuple,
        component_world orelse host_api_world,
        dispatch_world orelse "caller",
    });
    raw_wasm = provenanced_raw;

    const install_raw = b.addInstallBinFile(raw_wasm, "starling-raw.wasm");

    const provenance_tool = b.addExecutable(.{
        .name = "starling-engine-provenance",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "tools/componentizer/engine_provenance.zig",
            ),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const add_provenance = b.addRunArtifact(provenance_tool);
    add_provenance.addFileArg(raw_wasm);
    const provenance_wasm =
        add_provenance.addOutputFileArg("starling-raw.wasm");
    add_provenance.addArgs(&.{
        host_api_name,
        component_world orelse "js-dispatch",
        dispatch_world orelse "js-exports",
        if (features.stdio) "true" else "false",
        if (features.random) "true" else "false",
        if (features.clocks) "true" else "false",
        if (features.http) "true" else "false",
        if (features.fetch_event) "true" else "false",
    });
    raw_wasm = provenance_wasm;
    var aot_bundle_publish: ?*std.Build.Step.Run = null;
    if (!aot_engine)
        _ = addPrefixBinFile(b, null, raw_wasm, "starling-raw.wasm");

    var tool_manifest: std.ArrayList(u8) = .empty;
    tool_manifest.appendSlice(
        gpa,
        "{\n  \"schema\": \"starling-componentize-build-tools/v1\",\n  \"tools\": [",
    ) catch @panic("OOM");
    for (runtime_build_tools.items, 0..) |tool, index| {
        tool_manifest.appendSlice(
            gpa,
            if (index == 0) "\n" else ",\n",
        ) catch @panic("OOM");
        tool_manifest.appendSlice(gpa, b.fmt(
            "    {{\"name\": \"{s}\", \"path\": \"runtime-build-tools/{s}\"}}",
            .{ tool.name, tool.name },
        )) catch @panic("OOM");
        const install_tool = b.addInstallBinFile(
            tool.executable,
            b.fmt("runtime-build-tools/{s}", .{tool.name}),
        );
        b.getInstallStep().dependOn(&install_tool.step);
    }
    tool_manifest.appendSlice(
        gpa,
        if (runtime_build_tools.items.len == 0) "]\n}\n" else "\n  ]\n}\n",
    ) catch @panic("OOM");
    const tool_manifest_file = b.addWriteFiles().add(
        "runtime-build-tools.json",
        tool_manifest.items,
    );
    b.getInstallStep().dependOn(
        &b.addInstallBinFile(
            tool_manifest_file,
            "runtime-build-tools.json",
        ).step,
    );
    if (aot_engine) {
        if (is_debug) @panic("-Daot-engine does not support Debug builds");
        const weval_dep = b.lazyDependency("weval", .{}) orelse
            @panic("the pinned Weval artifact is required for -Daot-engine");
        const cache_primer = b.path("tools/componentizer/aot-cache-primer.js");
        const prime_cache = std.Build.Step.Run.create(b, "prime Weval IC cache");
        prime_cache.addFileArg(weval_dep.path("weval"));
        prime_cache.addFileInput(cache_primer);
        prime_cache.addArgs(&.{
            "weval",
            "-w",
            "--init-func",
            "starling-aot-cache-initialize",
            "--dir",
            ".",
            "--cache",
        });
        const cache = prime_cache.addOutputFileArg("starling-ics.wevalcache");
        prime_cache.addArg("-i");
        prime_cache.addFileArg(raw_wasm);
        prime_cache.addArg("-o");
        _ = prime_cache.addOutputFileArg("primed-starling-raw.wasm");
        prime_cache.setCwd(b.path("."));
        prime_cache.setStdIn(.{ .bytes = "tools/componentizer/aot-cache-primer.js\n" });
        prime_cache.removeEnvironmentVariable("STARLINGMONKEY_CONFIG");
        prime_cache.removeEnvironmentVariable("ENABLE_PBL");
        prime_cache.setEnvironmentVariable("RUST_MIN_STACK", "8388608");
        prime_cache.setEnvironmentVariable("WASMTIME_BACKTRACE_DETAILS", "1");

        const seal_cache = b.addRunArtifact(aot_cache_tool);
        seal_cache.addArg("seal");
        seal_cache.addArg("--engine");
        seal_cache.addFileArg(raw_wasm);
        seal_cache.addArg("--weval");
        seal_cache.addFileArg(weval_dep.path("weval"));
        seal_cache.addArg("--cache");
        seal_cache.addFileArg(cache);
        seal_cache.addArg("--cache-out");
        const sealed_cache =
            seal_cache.addOutputFileArg("starling-ics.wevalcache");
        seal_cache.addArg("--primer");
        seal_cache.addFileArg(cache_primer);
        seal_cache.addArgs(&.{ "--feature-abi", feature_abi, "--out" });
        const manifest = seal_cache.addOutputFileArg("starling-ics.wevalcache.manifest");

        _ = addPrefixBinFile(
            b,
            aot_generation,
            raw_wasm,
            "starling-raw.wasm",
        );
        _ = addPrefixBinFile(
            b,
            aot_generation,
            sealed_cache,
            "starling-ics.wevalcache",
        );
        _ = addPrefixBinFile(
            b,
            aot_generation,
            manifest,
            "starling-ics.wevalcache.manifest",
        );

        const publish_bundle = b.addRunArtifact(aot_cache_tool);
        publish_bundle.addArg("publish-prefix");
        publish_bundle.addArg("--target");
        publish_bundle.addDirectoryArg(
            b.graph.path(.install_prefix, ""),
        );
        publish_bundle.addArg("--generation");
        publish_bundle.addDirectoryArg(aot_generation.?.getDirectory());
        publish_bundle.addArgs(&.{ "--feature-abi", feature_abi });
        publish_bundle.has_side_effects = true;
        aot_bundle_publish = publish_bundle;
        const aot_step = b.step(
            "aot-engine",
            "Build and install the AOT engine with its sealed Weval cache",
        );
        aot_step.dependOn(&publish_bundle.step);
    }

    // ---- Componentization tooling (port of componentize.sh.in + adapter copy) ----
    // Install the preview1 adapter and a generated componentize.sh next to
    // starling-raw.wasm so the runtime can be turned into a component.
    const adapter = if (preview1_adapter) |path|
        inputPath(b, path)
    else
        b.path(b.pathJoin(&.{ ctx.host_api_dir, if (is_debug) "preview1-adapter-debug" else "preview1-adapter-release", "wasi_snapshot_preview1.wasm" }));
    b.getInstallStep().dependOn(&b.addInstallBinFile(adapter, "preview1-adapter.wasm").step);
    const installed_component_wit = component_wit orelse
        b.pathJoin(&.{ ctx.host_api_dir, "wit" });
    const install_wit = b.addInstallDirectory(.{
        .source_dir = inputPath(b, installed_component_wit),
        .install_dir = .bin,
        .install_subdir = "component-wit",
        .include_extensions = &.{".wit"},
    });
    b.getInstallStep().dependOn(&install_wit.step);
    const surface_wit = dispatch_wit orelse "tools/feature-surface";
    const install_surface_wit = b.addInstallDirectory(.{
        .source_dir = inputPath(b, surface_wit),
        .install_dir = .bin,
        .install_subdir = "surface-wit",
        .include_extensions = &.{".wit"},
    });
    b.getInstallStep().dependOn(&install_surface_wit.step);
    const install_feature_wit = b.addInstallDirectory(.{
        .source_dir = b.path(b.pathJoin(&.{ ctx.host_api_dir, "wit" })),
        .install_dir = .bin,
        .install_subdir = "feature-wit",
        .include_extensions = &.{".wit"},
    });
    b.getInstallStep().dependOn(&install_feature_wit.step);
    const adapter = b.pathJoin(&.{ ctx.wasi020, if (is_debug) "preview1-adapter-debug" else "preview1-adapter-release", "wasi_snapshot_preview1.wasm" });
    _ = addPrefixBinFile(
        b,
        aot_generation,
        b.path(adapter),
        "preview1-adapter.wasm",
    );
    const default_wit = b.pathJoin(&.{ ctx.host_api_dir, "wit" });
    for ([_]struct { source: []const u8, destination: []const u8 }{
        .{
            .source = component_wit orelse default_wit,
            .destination = "component-wit",
        },
        .{
            .source = dispatch_wit orelse default_wit,
            .destination = "surface-wit",
        },
        .{
            .source = default_wit,
            .destination = "feature-wit",
        },
    }) |wit| {
        _ = addPrefixBinDirectory(
            b,
            aot_generation,
            b.path(wit.source),
            wit.destination,
            &.{".wit"},
        );
    }

    // componentize.sh references the tools via `$(dirname "$0")/…`, so install them
    // alongside it (relocatable, mirrors the CMake build directory layout).
    if (b.lazyDependency("wasm-tools", .{})) |d|
        _ = addPrefixBinFile(b, aot_generation, d.path("wasm-tools"), "wasm-tools");
    if (b.lazyDependency("wasmtime", .{})) |d|
        _ = addPrefixBinFile(b, aot_generation, d.path("wasmtime"), "wasmtime");
    if (b.lazyDependency("weval", .{})) |d| {
        if (aot_generation) |generation| {
            _ = generation.addCopyDirectory(
                d.path("."),
                "weval-package",
                .{},
            );
            _ = addPrefixBinFile(b, aot_generation, d.path("weval"), "weval");
        } else {
            _ = addPrefixBinFile(b, aot_generation, d.path("weval"), "weval");
        }
    }

    const componentize_sh = renderComponentizeScript(
        b,
        component_world orelse host_api_world,
        dispatch_world orelse "caller",
        features,
    );
    const componentize_sh = renderComponentizeScript(b, component_world, aot_engine);
    const inst_componentize = addPrefixBinFile(
        b,
        aot_generation,
        componentize_sh,
        "componentize.sh",
    );
    // Installed generated files aren't executable; componentize.sh is invoked
    // directly (e.g. by tests/test.sh), so mark it +x after install.
    const installed_componentize = b.graph.path(
        .install_prefix,
        "bin/componentize.sh",
    );
    if (aot_generation) |generation| {
        const chmod = b.addSystemCommand(&.{ "chmod", "+x" });
        chmod.addFileArg(
            generation.getDirectory().path(b, "bin/componentize.sh"),
        );
        chmod.step.dependOn(inst_componentize);
        aot_generation_chmod = chmod;
    } else {
        const chmod = b.addSystemCommand(&.{ "chmod", "+x" });
        chmod.addFileArg(installed_componentize);
        chmod.step.dependOn(inst_componentize);
        b.getInstallStep().dependOn(&chmod.step);
    }

    // features.json: a machine-readable record of the resolved feature
    // selection for this build, installed next to componentize.sh/
    // starling-raw.wasm (cataggar/StarlingMonkey#6 Phase 6 diagnostics).
    // Consumed by tests/feature-selection/ to assert build-option ->
    // resolved-feature mapping without re-parsing build.zig, and useful for
    // humans inspecting `zig-out/bin/` to see what a given build selected.
    const features_json = b.fmt(
        \\{{
        \\  "host-api": "{s}",
        \\  "component-world": "{s}",
        \\  "surface-world": "{s}",
        \\  "stdio": {},
        \\  "random": {},
        \\  "clocks": {},
        \\  "http": {},
        \\  "fetch-event": {}
        \\}}
        \\
    , .{
        host_api_identity,
        component_world orelse host_api_world,
        dispatch_world orelse "caller",
        features.stdio,
        features.random,
        features.clocks,
        features.http,
        features.fetch_event,
    });
    const features_json_file = b.addWriteFiles().add("features.json", features_json);
    _ = addPrefixBinFile(
        b,
        aot_generation,
        features_json_file,
        "features.json",
    );

    // `zig build smoke-test`: componentize a trivial script and validate the
    // resulting component. Runs the *installed* componentize.sh so it finds
    // starling-raw.wasm, the adapter and the tools next to itself. (The full
    // multi-module e2e smoke.js needs the test harness's --strip-path-prefix and
    // is covered by the ported test suite, not this build step.)
    const smoke = b.step("smoke-test", "Componentize a trivial script and validate the component");
    const smoke_js = b.addWriteFiles().add("smoke.js", "addEventListener('fetch', e => e.respondWith(new Response('ok')));\nconsole.log('smoke ok');\n");
    _ = addPrefixBinFile(b, aot_generation, smoke_js, "smoke.js");
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
    test_step.dependOn(componentizer_test_step);
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
    const run_js_dispatch_tests = b.addRunArtifact(js_dispatch_tests);
    const js_dispatch_test_step =
        b.step("js-dispatch-test", "Run typed JavaScript dispatch bridge tests");
    js_dispatch_test_step.dependOn(&run_js_dispatch_tests.step);
    test_step.dependOn(js_dispatch_test_step);
    const resource_registry_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    resource_registry_test_mod.addIncludePath(b.path("include"));
    resource_registry_test_mod.addCSourceFiles(.{
        .files = &.{
            "runtime/resource_registry.cpp",
            "tests/resource_registry.cpp",
        },
        .flags = &.{
            "-std=gnu++23",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fno-exceptions",
            "-fno-rtti",
        },
        .language = .cpp,
    });
    const resource_registry_tests = b.addExecutable(.{
        .name = "resource-registry-tests",
        .root_module = resource_registry_test_mod,
    });
    const run_resource_registry_tests = b.addRunArtifact(resource_registry_tests);
    const resource_registry_test_step =
        b.step("resource-registry-test", "Run resource ownership and lifetime registry tests");
    resource_registry_test_step.dependOn(&run_resource_registry_tests.step);
    test_step.dependOn(resource_registry_test_step);
    const task_selection_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    task_selection_test_mod.addIncludePath(b.path("host-apis/wasi-0.2.0"));
    task_selection_test_mod.addCSourceFile(.{
        .file = b.path("tests/task-selection.cpp"),
        .flags = &.{ "-std=gnu++23", "-Wall", "-Wextra", "-Werror" },
        .language = .cpp,
    });
    const task_selection_tests = b.addExecutable(.{
        .name = "task-selection-tests",
        .root_module = task_selection_test_mod,
    });
    const run_task_selection_tests = b.addRunArtifact(task_selection_tests);
    const task_selection_test_step =
        b.step("task-selection-test", "Run oldest-ready task selection tests");
    task_selection_test_step.dependOn(&run_task_selection_tests.step);
    test_step.dependOn(task_selection_test_step);
    const heap_limit_tests = b.addSystemCommand(&.{ "bash", "tests/js-heap-limit/run.sh" });
    heap_limit_tests.addArg(b.graph.zig_exe);
    if (b.lazyDependency("wasmtime", .{})) |d|
        heap_limit_tests.addFileArg(d.path("wasmtime"));
    test_step.dependOn(&heap_limit_tests.step);
    const suite = b.addSystemCommand(&.{ "bash", "tests/run-suite.sh" });
    suite.addDirectoryArg(b.graph.path(.install_prefix, "bin"));
    suite.step.dependOn(b.getInstallStep());
    test_step.dependOn(&suite.step);
    const runtime_eval_test_step = b.step(
        "runtime-eval-test",
        "Run real unsnapshotted runtime CLI invocation tests",
    );
    const runtime_eval = b.addSystemCommand(&.{ "bash", "tests/runtime-eval/run.sh" });
    runtime_eval.addDirectoryArg(b.graph.path(.install_prefix, "bin"));
    runtime_eval.step.dependOn(b.getInstallStep());
    runtime_eval_test_step.dependOn(&runtime_eval.step);
    test_step.dependOn(runtime_eval_test_step);

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
    const host_api_matrix_failure_run = b.addSystemCommand(
        &.{ "bash", "tests/feature-selection/run-host-api-matrix-failure-proof.sh" },
    );
    feature_selection_test_step.dependOn(&host_api_matrix_failure_run.step);
    test_step.dependOn(feature_selection_test_step);

    // `zig build feature-selection-runtime-test`: the REQUIRED/FULL
    // component-level feature-selection suite
    // (tests/feature-selection/run-runtime-tests.sh). Unlike
    // `feature-selection-test` above, this actually builds a full
    // StarlingMonkey runtime for each of 10 feature combinations,
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
    const host_api_matrix_step = b.step(
        "host-api-production-matrix-test",
        "Run required Zig and CMake production matrices for every host API",
    );
    const host_api_zig_matrix_step = b.step(
        "host-api-zig-production-matrix-test",
        "Run version-matched Zig production component tests for every host API",
    );
    const host_api_zig_matrix_run = b.addSystemCommand(
        &.{ "bash", "tests/feature-selection/run-host-api-matrix.sh", "zig" },
    );
    host_api_zig_matrix_run.addArg(b.graph.zig_exe);
    host_api_zig_matrix_step.dependOn(&host_api_zig_matrix_run.step);
    const host_api_cmake_matrix_step = b.step(
        "host-api-cmake-production-matrix-test",
        "Run version-matched CMake production component tests for every host API",
    );
    const host_api_cmake_matrix_run = b.addSystemCommand(
        &.{ "bash", "tests/feature-selection/run-host-api-matrix.sh", "cmake" },
    );
    host_api_cmake_matrix_run.addArg(b.graph.zig_exe);
    host_api_cmake_matrix_step.dependOn(&host_api_cmake_matrix_run.step);
    const custom_host_step = b.step(
        "custom-host-production-test",
        "Run non-bindings custom host production tests through Zig and CMake",
    );
    const custom_host_run = b.addSystemCommand(
        &.{ "bash", "tests/feature-selection/run-custom-host-test.sh" },
    );
    custom_host_run.addArg(b.graph.zig_exe);
    custom_host_step.dependOn(&custom_host_run.step);
    host_api_matrix_step.dependOn(host_api_zig_matrix_step);
    host_api_matrix_step.dependOn(host_api_cmake_matrix_step);
    host_api_matrix_step.dependOn(custom_host_step);
    // `zig build wit-imports-e2e-test`: the "wit-imports" roadmap phase's E2E
    // suite (tests/e2e/wit-imports). Builds a dedicated dispatch-enabled
    // reactor against a fixture-specific WIT world that additionally
    // *imports* a custom `test:wit-imports/host@1.2.3` interface and
    // world-level functions (not just the usual export-only js-dispatch world),
    // componentizes
    // tests/e2e/wit-imports/component.js against it (a JS module that
    // `import`s host functions with zero user-written glue), and drives
    // every export through a Wasmtime 42 host that implements the custom
    // interface and root imports dynamically (tests/compat/runtime/invoker's
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
    // result<T,E> both-payload and void-ok-payload forms), plus imported
    // resources through constructors, methods, statics, borrow parameters,
    // owned transfers, stale-handle rejection, and resource drops. Each runs
    // through a real host-side transform, now that cataggar/wabt PR #335 (see
    // build.zig.zon's `.wasip3` pin) fixed the reverse (`--js-imports`)
    // bridge's type gate and lowering for all of them. Root-function coverage
    // verifies the default-import convention, arguments/results,
    // void=>undefined, repeated calls, traps, missing-import diagnostics, and
    // a recursive alias/variant/record chain reached through a root `use`.
    // Like `compat-bridge-test`, this is deliberately NOT part of `test`: it
    // requires a Rust toolchain and takes several minutes end to end (fresh Zig build +
    // Cranelift compilation under load), so it must be invoked explicitly.
    const wit_imports_e2e_test_step = b.step("wit-imports-e2e-test", "Run the WIT interface/root-imports E2E suite (tests/e2e/wit-imports; requires Rust, not part of `test`)");
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
        const inst_engine = addPrefixBinFile(
            b,
            aot_generation,
            engine_lib.getEmittedBin(),
            "starling-engine.wasm",
        );
        inst_engine.dependOn(&engine_lib.step);
        engine_step.dependOn(inst_engine);
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
        const inst_shell = addPrefixBinFile(
            b,
            aot_generation,
            shell_lib.getEmittedBin(),
            "starling-shell.wasm",
        );
        inst_shell.dependOn(&shell_lib.step);
        shell_step.dependOn(inst_shell);
    }

    if (aot_bundle_publish) |publisher| {
        const install = b.getInstallStep();
        if (install.dependencies.items.len != 0)
            @panic("AOT installation prerequisites must target the private generation");
        if (aot_generation_chmod) |chmod|
            publisher.step.dependOn(&chmod.step);
        install.dependOn(&publisher.step);
    }
}

// Render componentize.sh from componentize.sh.in, pointing the tool paths at the
// binaries installed next to it (resolved at runtime via `$(dirname "$0")`).
fn renderComponentizeScript(
    b: *std.Build,
    component_world: ?[]const u8,
    surface_target_world: []const u8,
    features: Features,
    aot_engine: bool,
) std.Build.LazyPath {
    const template = @embedFile("componentize.sh.in");
    var buf = std.ArrayList(u8).empty;
    const gpa = b.allocator;
    var rest: []const u8 = template;
    const subs = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "@AOT@", .to = "0" },
        .{ .from = "@EXTERNAL_RUNTIME_FILE@", .to = "starling-raw.wasm" },
        .{ .from = "@WASMTIME_DIR@", .to = "$(dirname \"$0\")" },
        .{ .from = "@WASM_TOOLS_BIN@", .to = "$(dirname \"$0\")/wasm-tools" },
        .{ .from = "@WEVAL_BIN@", .to = "$(dirname \"$0\")/weval" },
        .{ .from = "@AOT@", .to = if (aot_engine) "1" else "0" },
        .{ .from = "@AOT_DRIVER@", .to = "native" },
        .{ .from = "@COMPONENT_WORLD@", .to = component_world orelse "" },
        .{ .from = "@SURFACE_TARGET_WORLD@", .to = surface_target_world },
        .{ .from = "@FEATURE_STDIO@", .to = if (features.stdio) "1" else "0" },
        .{ .from = "@FEATURE_RANDOM@", .to = if (features.random) "1" else "0" },
        .{ .from = "@FEATURE_CLOCKS@", .to = if (features.clocks) "1" else "0" },
        .{ .from = "@FEATURE_HTTP@", .to = if (features.http) "1" else "0" },
        .{ .from = "@FEATURE_FETCH_EVENT@", .to = if (features.fetch_event) "1" else "0" },
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
    const io = b.graph.io;
    var dir = switch (wit) {
        .src_path => |sp| blk: {
            const path = sp.owner.root.join(b.allocator, sp.sub_path) catch |err|
                std.process.fatal("failed to resolve WIT directory '{s}': {t}", .{ sp.sub_path, err });
            break :blk path.root_dir.handle.openDir(
                io,
                path.sub_path,
                .{ .iterate = true },
            ) catch |err| std.process.fatal("failed to open WIT directory '{s}': {t}", .{ sp.sub_path, err });
        },
        .cwd_relative => |path| if (std.fs.path.isAbsolute(path))
            std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err|
                std.process.fatal("failed to open WIT directory '{s}': {t}", .{ path, err })
        else
            std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err|
                std.process.fatal("failed to open WIT directory '{s}': {t}", .{ path, err }),
        else => return,
    };
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch |err|
        std.process.fatal("failed to walk WIT directory '{s}': {t}", .{ wit.getDisplayName(), err });
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch |err|
        std.process.fatal("failed to read WIT directory '{s}': {t}", .{ wit.getDisplayName(), err })) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wit")) continue;
        files.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (files.items) |path| cmd.addFileInput(wit.path(b, path));
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
    "runtime/resource_registry.cpp",
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
