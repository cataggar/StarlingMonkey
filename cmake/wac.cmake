set(STARLING_WAC_VERSION "0.10.1")

function(starling_select_wac_artifact OUT_URL OUT_SHA256 SYSTEM_NAME PROCESSOR)
    string(TOLOWER "${SYSTEM_NAME}" SYSTEM_NAME_NORMALIZED)
    string(TOLOWER "${PROCESSOR}" PROCESSOR_NORMALIZED)

    if(SYSTEM_NAME_NORMALIZED STREQUAL "linux")
        set(WAC_OS "unknown-linux-musl")
    elseif(SYSTEM_NAME_NORMALIZED STREQUAL "darwin" OR
           SYSTEM_NAME_NORMALIZED STREQUAL "macos")
        set(WAC_OS "apple-darwin")
    else()
        message(FATAL_ERROR
            "WAC ${STARLING_WAC_VERSION} is unsupported on host OS "
            "'${SYSTEM_NAME}' (supported: Linux and macOS)"
        )
    endif()

    if(PROCESSOR_NORMALIZED MATCHES "^(x86_64|amd64)$")
        set(WAC_ARCH "x86_64")
    elseif(PROCESSOR_NORMALIZED MATCHES "^(aarch64|arm64)$")
        set(WAC_ARCH "aarch64")
    else()
        message(FATAL_ERROR
            "WAC ${STARLING_WAC_VERSION} is unsupported on host architecture "
            "'${PROCESSOR}' (supported: x86_64 and aarch64)"
        )
    endif()

    set(WAC_ARTIFACT "wac-cli-${WAC_ARCH}-${WAC_OS}")
    if(WAC_ARTIFACT STREQUAL "wac-cli-x86_64-unknown-linux-musl")
        set(WAC_DIGEST "250c11762916ba733c7d22b62487580f21270ec9dde4f13460ea69d300e25406")
    elseif(WAC_ARTIFACT STREQUAL "wac-cli-aarch64-unknown-linux-musl")
        set(WAC_DIGEST "278e190120e2922a5bb0ad8d105a53ecb159e027e72cbd709da6ac1bb1980355")
    elseif(WAC_ARTIFACT STREQUAL "wac-cli-x86_64-apple-darwin")
        set(WAC_DIGEST "f8f204c46e12a553bb38519abca7206a8bc4c41d6e387ed0820298530c50769c")
    elseif(WAC_ARTIFACT STREQUAL "wac-cli-aarch64-apple-darwin")
        set(WAC_DIGEST "f7315f2ebf764efc0c7e9688c854f972a8ac41ed1b68fd01f4192226307a8c53")
    else()
        message(FATAL_ERROR "No pinned checksum for WAC artifact '${WAC_ARTIFACT}'")
    endif()

    set(${OUT_URL}
        "https://github.com/bytecodealliance/wac/releases/download/v${STARLING_WAC_VERSION}/${WAC_ARTIFACT}"
        PARENT_SCOPE
    )
    set(${OUT_SHA256} "${WAC_DIGEST}" PARENT_SCOPE)
endfunction()
