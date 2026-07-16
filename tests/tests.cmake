enable_testing()

find_program(BASH_PROGRAM bash)
include("wasmtime")
include("weval")

add_test(
    NAME wac-platform-selection
    COMMAND ${BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/tests/cmake/run-wac-tests.sh
)
if(WEVAL)
    add_test(
        NAME weval-install-package
        COMMAND
            ${BASH_PROGRAM}
            ${CMAKE_SOURCE_DIR}/tests/cmake/run-weval-install-test.sh
            ${CMAKE_BINARY_DIR}
    )
    set_tests_properties(weval-install-package PROPERTIES TIMEOUT 300)
endif()

if(NOT CMAKE_CROSSCOMPILING)
    add_executable(resource-registry-tests
        ${CMAKE_SOURCE_DIR}/runtime/resource_registry.cpp
        ${CMAKE_SOURCE_DIR}/tests/resource_registry.cpp
    )
    target_include_directories(resource-registry-tests PRIVATE ${CMAKE_SOURCE_DIR}/include)
    target_compile_features(resource-registry-tests PRIVATE cxx_std_23)
    add_test(NAME resource-registry COMMAND resource-registry-tests)

    add_executable(task-selection-tests
        ${CMAKE_SOURCE_DIR}/tests/task-selection.cpp
    )
    target_include_directories(
        task-selection-tests PRIVATE ${CMAKE_SOURCE_DIR}/host-apis/wasi-0.2.0
    )
    target_compile_features(task-selection-tests PRIVATE cxx_std_23)
    add_test(NAME task-selection COMMAND task-selection-tests)
endif()

add_test(
    NAME componentize-exact-surface
    COMMAND
        ${BASH_PROGRAM}
        ${CMAKE_SOURCE_DIR}/tests/feature-selection/run-cmake-surface-test.sh
        ${CMAKE_BINARY_DIR}
        ${CMAKE_BINARY_DIR}/wasm-tools
        "${FEATURE_SURFACE_CASE}"
        "${HOST_API_VERSION}"
)
set_tests_properties(componentize-exact-surface PROPERTIES TIMEOUT 180)

if(FEATURE_TUPLE STREQUAL "11111")
    add_test(
        NAME runtime-eval-cli
        COMMAND
            ${BASH_PROGRAM}
            ${CMAKE_SOURCE_DIR}/tests/runtime-eval/run.sh
            ${CMAKE_BINARY_DIR}
    )
    set_tests_properties(runtime-eval-cli PROPERTIES TIMEOUT 180)
endif()

function(test_e2e TEST_NAME)
    get_target_property(RUNTIME_DIR starling-raw.wasm BINARY_DIR)
    add_test(e2e-${TEST_NAME} ${BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/tests/test.sh ${RUNTIME_DIR} ${CMAKE_SOURCE_DIR}/tests/e2e/${TEST_NAME})
    set_property(TEST e2e-${TEST_NAME} PROPERTY ENVIRONMENT "WASMTIME=${WASMTIME};WASM_TOOLS=${WASM_TOOLS_DIR}/wasm-tools")
    set_tests_properties(e2e-${TEST_NAME} PROPERTIES TIMEOUT 120)
endfunction()

function(test_integration TEST_NAME)
    get_target_property(RUNTIME_DIR starling-raw.wasm BINARY_DIR)

    add_test(integration-${TEST_NAME} ${BASH_PROGRAM} ${CMAKE_SOURCE_DIR}/tests/test.sh ${RUNTIME_DIR} ${CMAKE_SOURCE_DIR}/tests/integration/${TEST_NAME} test-server.wasm ${TEST_NAME})
    set_property(TEST integration-${TEST_NAME} PROPERTY ENVIRONMENT "WASMTIME=${WASMTIME};WASM_TOOLS=${WASM_TOOLS_DIR}/wasm-tools;")
    set_tests_properties(integration-${TEST_NAME} PROPERTIES TIMEOUT 120)
endfunction()

function(integration_tests)
    get_target_property(RUNTIME_DIR starling-raw.wasm BINARY_DIR)
    set(TESTS_DIR ${CMAKE_SOURCE_DIR}/tests/integration)
    set(DEPS ${RUNTIME_DIR}/componentize.sh starling-raw.wasm ${TESTS_DIR}/test-server.js ${TESTS_DIR}/handlers.js
    )
    foreach(TEST_NAME ${ARGV})
        list(APPEND DEPS ${TESTS_DIR}/${TEST_NAME}/${TEST_NAME}.js)
    endforeach()

    add_custom_command(
            OUTPUT test-server.wasm
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
            COMMAND ${CMAKE_COMMAND} -E env "WASM_TOOLS=${WASM_TOOLS_DIR}/wasm-tools" env "PREOPEN_DIR=${CMAKE_SOURCE_DIR}/tests" ${RUNTIME_DIR}/componentize.sh ${TESTS_DIR}/test-server.js test-server.wasm
            DEPENDS ${DEPS}
            VERBATIM
    )
    add_custom_target(integration-test-server DEPENDS test-server.wasm)
    if(WEVAL)
        add_dependencies(integration-test-server starling-ics.wevalcache)
    endif()

    foreach(TEST_NAME ${ARGV})
        test_integration(${TEST_NAME})
    endforeach()
endfunction()

test_e2e(blob)
test_e2e(eventloop-stall)
test_e2e(headers)
test_e2e(runtime-err)
test_e2e(smoke)
test_e2e(syntax-err)
test_e2e(tla-err)
test_e2e(tla-runtime-resolve)
test_e2e(tla)
test_e2e(stream-forwarding)
test_e2e(multi-stream-forwarding)
test_e2e(teed-stream-as-outgoing-body)
test_e2e(init-script)
test_e2e(no-init-location)
test_e2e(init-location)

integration_tests(
    blob
    btoa
    crypto
    event
    fetch
    performance
    timers
)
