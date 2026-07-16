if(NOT DEFINED ROOT)
    message(FATAL_ERROR "ROOT is required")
endif()
include("${ROOT}/cmake/wac.cmake")

function(assert_wac SYSTEM_NAME PROCESSOR ARTIFACT SHA256)
    starling_select_wac_artifact(URL ACTUAL_SHA256 "${SYSTEM_NAME}" "${PROCESSOR}")
    if(NOT URL MATCHES "/${ARTIFACT}$")
        message(FATAL_ERROR "${SYSTEM_NAME}/${PROCESSOR}: unexpected WAC URL ${URL}")
    endif()
    if(NOT ACTUAL_SHA256 STREQUAL SHA256)
        message(FATAL_ERROR
            "${SYSTEM_NAME}/${PROCESSOR}: expected ${SHA256}, got ${ACTUAL_SHA256}"
        )
    endif()
endfunction()

assert_wac(
    Linux x86_64
    wac-cli-x86_64-unknown-linux-musl
    250c11762916ba733c7d22b62487580f21270ec9dde4f13460ea69d300e25406
)
assert_wac(
    Linux aarch64
    wac-cli-aarch64-unknown-linux-musl
    278e190120e2922a5bb0ad8d105a53ecb159e027e72cbd709da6ac1bb1980355
)
assert_wac(
    Darwin x86_64
    wac-cli-x86_64-apple-darwin
    f8f204c46e12a553bb38519abca7206a8bc4c41d6e387ed0820298530c50769c
)
assert_wac(
    Darwin arm64
    wac-cli-aarch64-apple-darwin
    f7315f2ebf764efc0c7e9688c854f972a8ac41ed1b68fd01f4192226307a8c53
)

cmake_host_system_information(RESULT HOST_PROCESSOR QUERY OS_PLATFORM)
starling_select_wac_artifact(
    HOST_URL HOST_SHA256 "${CMAKE_HOST_SYSTEM_NAME}" "${HOST_PROCESSOR}"
)
message(STATUS "Current host selects ${HOST_URL}")
