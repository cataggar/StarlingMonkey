ncpus := num_cpus()
justdir := justfile_directory()
mode := 'debug'
builddir := justdir / 'cmake-build-' + mode
reconfigure := 'false'
zig := env_var_or_default('ZIG', 'zig')

alias b := build
alias t := test
alias w := wpt-test
alias c := componentize
alias fmt := format

# List all recipes
default:
    @echo 'Default mode {{ mode }}'
    @echo 'Default build directory {{ builddir }}'
    @just --list

# Build specified target or all otherwise
build target="all" *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    echo 'Setting build directory to {{ builddir }}, build type {{ if mode == "weval" { "ReleaseSmall (Zig AOT)" } else { capitalize(mode) } }}'

    if [[ '{{ mode }}' == weval ]]; then
        case '{{ target }}' in
            ''|all|starling|starling-raw.wasm|starling-ics.wevalcache)
                zig_step=()
                ;;
            *)
                zig_step=('{{ target }}')
                ;;
        esac
        {{ quote(zig) }} build "${zig_step[@]}" --prefix '{{ builddir }}' \
            -Doptimize=ReleaseSmall -Daot-engine=true {{ flags }}
        if [[ '{{ target }}' == starling ]]; then
            output_dir='{{ builddir }}-outputs'
            mkdir -p "$output_dir"
            output="$output_dir/starling.wasm"
            trap 'rm -f "$output"' EXIT
            '{{ builddir }}/bin/componentize.sh' \
                --output "$output"
            mv "$output" '{{ builddir }}/starling.wasm'
            trap - EXIT
        fi
        exit
    fi

    # Only run configure step if build directory doesn't exist yet
    if ! {{ path_exists(builddir) }} || {{ reconfigure }} = 'true'; then
        cmake -S . -B {{ builddir }} {{ flags }} \
            -DCMAKE_BUILD_TYPE={{ capitalize(mode) }}
    else
        echo 'build directory already exists, skipping cmake configure'
    fi

    # Build target
    cmake --build {{ builddir }} --parallel {{ ncpus }} {{ if target == "" { "" } else { "--target " + target } }}

# Run clean target
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ mode }}' == weval ]]; then
        rm -rf '{{ builddir }}'
    else
        cmake --build '{{ builddir }}' --target clean
    fi

[private]
[confirm('proceed?')]
do_clean:
    rm -rf {{ builddir }}

# Remove build directory
clean-all: && do_clean
    @echo "This will remove {{builddir}}"

# Run clang-tidy
lint: (build "clang-tidy")

# Run clang-tidy and apply offered fixes
lint-fix: (build "clang-tidy-fix")

# Componentize js script
componentize script="" outfile="starling.wasm": build
    {{ if mode == "weval" { builddir / "bin/componentize.sh" } else { builddir / "componentize.sh" } }} {{ script }} -o {{ outfile }}

# Componentize and serve script with wasmtime
serve script: (componentize script)
    wasmtime serve -S common starling.wasm

# Format code using clang-format. Use --fix to fix files inplace
format *ARGS:
    {{ justdir }}/scripts/clang-format.sh {{ ARGS }}

# Build and test the sealed Zig AOT runtime
[group('aot')]
aot-build *flags:
    {{ quote(zig) }} build --prefix '{{ builddir }}' \
        -Doptimize=ReleaseSmall -Daot-engine=true {{ flags }}

[group('aot')]
aot-test: aot-build
    {{ justdir }}/tests/componentizer/run-legacy-aot-targets.sh \
        {{ quote(zig) }} '{{ builddir }}'
    {{ quote(zig) }} build componentizer-test --prefix '{{ builddir }}' \
        -Doptimize=ReleaseSmall -Daot-engine=true
    {{ quote(zig) }} build aot-engine-test --prefix '{{ builddir }}' \
        -Doptimize=ReleaseSmall -Daot-engine=true

[group('aot')]
aot-build-prefix-test: aot-build
    {{ justdir }}/tests/componentizer/run-build-prefix-publication.sh \
        {{ quote(zig) }} '{{ builddir }}'

[group('aot')]
aot-package outdir="release-artifacts": aot-build
    {{ justdir }}/scripts/package-aot-release.sh '{{ builddir }}' '{{ outdir }}'

# Run integration tests, or the componentizer/AOT suites for mode=weval
test regex="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ '{{ mode }}' == weval ]]; then
        just --justfile '{{ justdir }}/justfile' zig={{ quote(zig) }} \
            builddir='{{ builddir }}' aot-test
    else
        just --justfile '{{ justdir }}/justfile' zig={{ quote(zig) }} mode='{{ mode }}' \
            builddir='{{ builddir }}' build integration-test-server
        just --justfile '{{ justdir }}/justfile' zig={{ quote(zig) }} mode='{{ mode }}' \
            builddir='{{ builddir }}' build wpt-runtime
        ctest --test-dir '{{ builddir }}' -j '{{ ncpus }}' --output-on-failure \
            {{ if regex == "" { regex } else { "-R " + regex } }}
    fi

# Run web platform test suite
[group('wpt')]
wpt-test filter="": (build "wpt-runtime")
    WPT_FILTER={{ filter }} ctest --test-dir {{ builddir }} -R wpt --verbose

# Update web platform test expectations
[group('wpt')]
wpt-update filter="": (build "wpt-runtime")
    WPT_FLAGS="--update-expectations" WPT_FILTER={{ filter }} ctest --test-dir {{ builddir }} -R wpt --verbose

# Run wpt server
[group('wpt')]
wpt-server: (build "wpt-runtime")
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ builddir }}
    wpt_root=$(grep '^CPM_PACKAGE_wpt-suite_SOURCE_DIR:INTERNAL=' CMakeCache.txt | cut -d'=' -f2-)

    echo "Using wpt-suite at ${wpt_root}"
    WASMTIME_BACKTRACE_DETAILS= node {{ justdir }}/tests/wpt-harness/run-wpt.mjs --wpt-root=${wpt_root} -vv --interactive

# Prepare WPT hosts
[group('wpt')]
wpt-setup:
    cat deps/wpt-hosts | sudo tee -a /etc/hosts
