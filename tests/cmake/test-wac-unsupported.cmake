if(NOT DEFINED ROOT)
    message(FATAL_ERROR "ROOT is required")
endif()
include("${ROOT}/cmake/wac.cmake")
starling_select_wac_artifact(
    URL SHA256
    "${TEST_SYSTEM_NAME}"
    "${TEST_PROCESSOR}"
)
