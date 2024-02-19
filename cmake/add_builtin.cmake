function(add_builtin)
    if (ARGC EQUAL 1)
        list(GET ARGN 0 SRC)
        cmake_path(GET SRC STEM NAME)
        cmake_path(GET SRC PARENT_PATH DIR)
        string(REPLACE "/" "::" NS ${DIR})
        set(NS ${NS}::${NAME})
    else()
        cmake_parse_arguments(PARSE_ARGV 1 "" "" "" "SRC")
        list(GET ARGN 0 NS)
        set(SRC ${_SRC})
    endif()
    string(REPLACE "-" "_" NS ${NS})
    string(REPLACE "::" "_" LIB_NAME ${NS})
    message(STATUS "Adding builtin ${LIB_NAME}")

    add_library(${LIB_NAME} STATIC ${SRC})
    target_link_libraries(${LIB_NAME} PRIVATE spidermonkey extension_api)
    target_link_libraries(builtins PRIVATE ${LIB_NAME})
    file(APPEND $CACHE{INSTALL_BUILTINS} "NS_DEF(${NS})\n")
    return(PROPAGATE LIB_NAME)
endfunction()
