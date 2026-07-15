cmake_minimum_required(VERSION 3.27)
set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)

if (DEFINED ENV{HOST_API})
    set(HOST_API $ENV{HOST_API})
    if (EXISTS ${HOST_API})
        cmake_path(ABSOLUTE_PATH HOST_API)
    else ()
        set(HOST_API ${CMAKE_CURRENT_SOURCE_DIR}/host-apis/$ENV{HOST_API})
    endif()
    if (NOT EXISTS ${HOST_API})
        message(FATAL_ERROR "Host API `$ENV{HOST_API}` not found. The HOST_API environment \
            variable must be the name of a host API implementation provided in the `host-apis` \
            folder of StarlingMonkey, or be an absolute path pointing to custom host API implementation.")
    endif()
else()
    set(HOST_API ${CMAKE_CURRENT_SOURCE_DIR}/host-apis/wasi-0.2.10)
endif()
message(STATUS "Using host API: ${HOST_API}")

# Ensure that the CPM cache is created outside the build dir, even if no location is specified by the developer.
if(NOT DEFINED ENV{CPM_SOURCE_CACHE})
    set(ENV{CPM_SOURCE_CACHE} ${CMAKE_CURRENT_SOURCE_DIR}/deps/cpm_cache)
endif()
include("CPM")
include("toolchain")

project(StarlingMonkey)

option(FEATURE_STDIO "Enable WASI stdio capabilities" ON)
option(FEATURE_RANDOM "Enable WASI random capabilities" ON)
option(FEATURE_CLOCKS "Enable WASI clock capabilities" ON)
option(FEATURE_HTTP "Enable outgoing WASI HTTP capabilities" ON)
option(FEATURE_FETCH_EVENT "Enable incoming FetchEvent handling" ON)

foreach(FEATURE_NAME STDIO RANDOM CLOCKS HTTP FETCH_EVENT)
    if(FEATURE_${FEATURE_NAME})
        set(FEATURE_${FEATURE_NAME}_VALUE 1)
    else()
        set(FEATURE_${FEATURE_NAME}_VALUE 0)
    endif()
endforeach()

set(FEATURE_SURFACE_CASE "")
set(FEATURE_TUPLE
    "${FEATURE_STDIO_VALUE}${FEATURE_RANDOM_VALUE}${FEATURE_CLOCKS_VALUE}${FEATURE_HTTP_VALUE}${FEATURE_FETCH_EVENT_VALUE}"
)
if(FEATURE_TUPLE STREQUAL "11111")
    set(FEATURE_SURFACE_CASE "defaults")
elseif(FEATURE_TUPLE STREQUAL "00000")
    set(FEATURE_SURFACE_CASE "disable-all")
elseif(FEATURE_TUPLE STREQUAL "01111")
    set(FEATURE_SURFACE_CASE "disable-stdio")
elseif(FEATURE_TUPLE STREQUAL "10111")
    set(FEATURE_SURFACE_CASE "disable-random")
elseif(FEATURE_TUPLE STREQUAL "11011")
    set(FEATURE_SURFACE_CASE "disable-clocks")
elseif(FEATURE_TUPLE STREQUAL "11101")
    set(FEATURE_SURFACE_CASE "disable-http-only")
elseif(FEATURE_TUPLE STREQUAL "11110")
    set(FEATURE_SURFACE_CASE "disable-fetch-event-only")
endif()

add_compile_definitions(
    STARLING_FEATURE_STDIO=${FEATURE_STDIO_VALUE}
    STARLING_FEATURE_RANDOM=${FEATURE_RANDOM_VALUE}
    STARLING_FEATURE_CLOCKS=${FEATURE_CLOCKS_VALUE}
    STARLING_FEATURE_HTTP=${FEATURE_HTTP_VALUE}
    STARLING_FEATURE_FETCH_EVENT=${FEATURE_FETCH_EVENT_VALUE}
)

include("init-corrosion")

include("wasm-tools")
include("binaryen")
include("weval")
include("wasmtime")
include("cbindgen")

include("spidermonkey")
include("openssl")
include("${HOST_API}/host_api.cmake")
include("build-crates")
include("lint")

option(ENABLE_JS_DEBUGGER "Enable support for debugging content via a socket connection" ON)

add_library(extension_api INTERFACE include/extension-api.h runtime/encode.h runtime/decode.h)
if (ENABLE_JS_DEBUGGER)
    target_compile_definitions(extension_api INTERFACE ENABLE_JS_DEBUGGER)
endif()
target_link_libraries(extension_api INTERFACE rust-url spidermonkey)
target_include_directories(extension_api INTERFACE include deps/include runtime)

include("builtins")

include("tests/wpt-harness/wpt.cmake")

set(SOURCES
    runtime/js.cpp
    runtime/allocator.cpp
    runtime/encode.cpp
    runtime/decode.cpp
    runtime/engine.cpp
    runtime/event_loop.cpp
    runtime/js_dispatch.cpp
    runtime/resource_registry.cpp
    runtime/builtin.cpp
    runtime/script_loader.cpp
    runtime/debugger.cpp
    runtime/feature_stubs.c
)

add_executable(starling-raw.wasm ${SOURCES})

target_link_libraries(starling-raw.wasm PRIVATE host_api extension_api builtins spidermonkey rust-crates)

option(USE_WASM_OPT "use wasm-opt to optimize the StarlingMonkey binary" ON)

# For release builds, use wasm-opt to optimize the generated wasm file.
if (USE_WASM_OPT)
    if (CMAKE_BUILD_TYPE STREQUAL "Release")
        add_custom_command(
                TARGET starling-raw.wasm
                POST_BUILD
                COMMAND ${WASM_OPT} --strip-debug -O3 -o starling-raw.wasm starling-raw.wasm
                WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        )
    elseif (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
        add_custom_command(
                TARGET starling-raw.wasm
                POST_BUILD
                COMMAND ${WASM_OPT} -O3 -g -o starling-raw.wasm starling-raw.wasm
                WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        )
    endif()
else()
    if (CMAKE_BUILD_TYPE STREQUAL "Release")
        add_custom_command(
            TARGET starling-raw.wasm
            POST_BUILD
            COMMAND ${WASM_OPT} --strip-debug -O0 -o starling-raw.wasm starling-raw.wasm
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        )
    endif()
endif()

# build a compilation cache of ICs
if(WEVAL)
    include("weval")
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/null.js "function main() {}")
    add_custom_target(
        starling-ics.wevalcache
        ALL
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        COMMAND rm -f starling-ics.wevalcache
        COMMAND echo ./null.js | ${WEVAL_BIN} weval --dir . --show-stats --cache starling-ics.wevalcache -w -i starling-raw.wasm -o /dev/null
        DEPENDS starling-raw.wasm
        VERBATIM
    )
    set(WEVAL_CACHE_FILE "starling-ics.wevalcache")
    set(AOT 1)
else()
    set(AOT 0)
endif()

set(RUNTIME_FILE "starling-raw.wasm")
set(ADAPTER_FILE "preview1-adapter.wasm")
set(WAC_BIN "${CMAKE_CURRENT_BINARY_DIR}/wac")
set(WAC_URL "https://github.com/bytecodealliance/wac/releases/download/v0.10.1/wac-cli-x86_64-unknown-linux-musl")
set(WAC_SHA256 "250c11762916ba733c7d22b62487580f21270ec9dde4f13460ea69d300e25406")
execute_process(
    COMMAND
        bash "${CMAKE_CURRENT_SOURCE_DIR}/tools/download-wac.sh"
        "${WAC_URL}" "${WAC_SHA256}" "${WAC_BIN}"
    COMMAND_ERROR_IS_FATAL ANY
)
if(DEFINED ENV{ZIG})
    set(ZIG_PROGRAM "$ENV{ZIG}")
else()
    find_program(ZIG_PROGRAM NAMES zig REQUIRED NO_CMAKE_FIND_ROOT_PATH)
endif()
execute_process(
    COMMAND "${ZIG_PROGRAM}" version
    OUTPUT_VARIABLE ZIG_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)
if(ZIG_VERSION VERSION_LESS 0.17)
    message(FATAL_ERROR "starling-feature-surface requires Zig 0.17 or newer; found ${ZIG_VERSION}")
endif()

set(FEATURE_SURFACE_BIN "${CMAKE_CURRENT_BINARY_DIR}/starling-feature-surface")
set(FEATURE_SURFACE_LOCAL_CACHE "${CMAKE_CURRENT_BINARY_DIR}/zig-cache/feature-surface-local")
set(FEATURE_SURFACE_GLOBAL_CACHE "${CMAKE_CURRENT_BINARY_DIR}/zig-cache/feature-surface-global")
add_custom_command(
    OUTPUT "${FEATURE_SURFACE_BIN}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
            "${FEATURE_SURFACE_LOCAL_CACHE}" "${FEATURE_SURFACE_GLOBAL_CACHE}"
    COMMAND "${CMAKE_COMMAND}" -E env
            "ZIG_LOCAL_CACHE_DIR=${FEATURE_SURFACE_LOCAL_CACHE}"
            "ZIG_GLOBAL_CACHE_DIR=${FEATURE_SURFACE_GLOBAL_CACHE}"
            "${ZIG_PROGRAM}" build-exe
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/feature-surface/main.zig"
            -OReleaseSmall
            "-femit-bin=${FEATURE_SURFACE_BIN}"
    DEPENDS
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/feature-surface/main.zig"
            "${CMAKE_CURRENT_SOURCE_DIR}/tools/feature-surface/surface.zig"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    VERBATIM
)
add_custom_target(starling-feature-surface-helper ALL DEPENDS "${FEATURE_SURFACE_BIN}")

set(FEATURE_WIT_DIR "${CMAKE_CURRENT_BINARY_DIR}/feature-wit")
file(GLOB_RECURSE FEATURE_WIT_FILES
    CONFIGURE_DEPENDS
    RELATIVE "${HOST_API}/wit"
    "${HOST_API}/wit/*.wit"
)
foreach(FEATURE_WIT_FILE IN LISTS FEATURE_WIT_FILES)
    get_filename_component(FEATURE_WIT_PARENT "${FEATURE_WIT_FILE}" DIRECTORY)
    file(MAKE_DIRECTORY "${FEATURE_WIT_DIR}/${FEATURE_WIT_PARENT}")
    configure_file(
        "${HOST_API}/wit/${FEATURE_WIT_FILE}"
        "${FEATURE_WIT_DIR}/${FEATURE_WIT_FILE}"
        COPYONLY
    )
endforeach()

set(SURFACE_TARGET_WIT_DIR "${CMAKE_CURRENT_BINARY_DIR}/surface-wit")
file(MAKE_DIRECTORY "${SURFACE_TARGET_WIT_DIR}")
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/feature-surface/caller.wit"
    "${SURFACE_TARGET_WIT_DIR}/caller.wit"
    COPYONLY
)

set(COMPONENT_WIT_DIR "${CMAKE_CURRENT_BINARY_DIR}/component-wit")
file(MAKE_DIRECTORY "${COMPONENT_WIT_DIR}")
foreach(FEATURE_WIT_FILE IN LISTS FEATURE_WIT_FILES)
    get_filename_component(FEATURE_WIT_PARENT "${FEATURE_WIT_FILE}" DIRECTORY)
    file(MAKE_DIRECTORY "${COMPONENT_WIT_DIR}/${FEATURE_WIT_PARENT}")
    configure_file(
        "${HOST_API}/wit/${FEATURE_WIT_FILE}"
        "${COMPONENT_WIT_DIR}/${FEATURE_WIT_FILE}"
        COPYONLY
    )
endforeach()

configure_file("${WASM_TOOLS_BIN}" "${CMAKE_CURRENT_BINARY_DIR}/wasm-tools" COPYONLY)
configure_file("${WASMTIME}" "${CMAKE_CURRENT_BINARY_DIR}/wasmtime" COPYONLY)
configure_file("${WEVAL_BIN}" "${CMAKE_CURRENT_BINARY_DIR}/weval" COPYONLY)
set(COMPONENT_WORLD "bindings")
set(SURFACE_TARGET_WORLD "caller")
set(FEATURE_STDIO "${FEATURE_STDIO_VALUE}")
set(FEATURE_RANDOM "${FEATURE_RANDOM_VALUE}")
set(FEATURE_CLOCKS "${FEATURE_CLOCKS_VALUE}")
set(FEATURE_HTTP "${FEATURE_HTTP_VALUE}")
set(FEATURE_FETCH_EVENT "${FEATURE_FETCH_EVENT_VALUE}")
configure_file("componentize.sh.in" "${CMAKE_CURRENT_BINARY_DIR}/componentize.sh" @ONLY)
if(EXISTS ${ADAPTER})
    configure_file(${ADAPTER} "${CMAKE_CURRENT_BINARY_DIR}/${ADAPTER_FILE}" COPYONLY)
endif()

function(componentize OUTPUT)
    set(options)
    set(oneValueArgs)
    set(multiValueArgs SOURCES)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    list(TRANSFORM ARG_SOURCES PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/)
    list(JOIN ARG_SOURCES " " SOURCES)
    get_target_property(RUNTIME_DIR starling-raw.wasm BINARY_DIR)

    add_custom_command(
            OUTPUT ${OUTPUT}.wasm
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
            COMMAND ${RUNTIME_DIR}/componentize.sh ${SOURCES} -o ${OUTPUT}.wasm
            DEPENDS ${ARG_SOURCES} ${RUNTIME_DIR}/componentize.sh
                    starling-raw.wasm starling-feature-surface-helper
            VERBATIM
    )
    add_custom_target(${OUTPUT} DEPENDS ${OUTPUT}.wasm)
endfunction()

componentize(smoke-test SOURCES tests/e2e/smoke/smoke.js)
componentize(starling)

install(TARGETS starling-raw.wasm RUNTIME DESTINATION bin)
install(
    PROGRAMS
        "${CMAKE_CURRENT_BINARY_DIR}/componentize.sh"
        "${FEATURE_SURFACE_BIN}"
        "${CMAKE_CURRENT_BINARY_DIR}/wasm-tools"
        "${CMAKE_CURRENT_BINARY_DIR}/wasmtime"
        "${CMAKE_CURRENT_BINARY_DIR}/weval"
        "${WAC_BIN}"
    DESTINATION bin
)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${ADAPTER_FILE}" DESTINATION bin)
install(
    DIRECTORY
        "${FEATURE_WIT_DIR}"
        "${COMPONENT_WIT_DIR}"
        "${SURFACE_TARGET_WIT_DIR}"
    DESTINATION bin
)

include("tests/tests.cmake")
