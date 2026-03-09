cmake_minimum_required(VERSION 3.21)

project(
    webwrap
    VERSION 0.1.0
    DESCRIPTION "Cross-platform HTTP client/server library and CLI"
    LANGUAGES C CXX
)

if(APPLE)
    enable_language(OBJC)
    enable_language(OBJCXX)
endif()

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(CTest)

option(WEBWRAP_BUILD_TESTS "Build the test suite" ${BUILD_TESTING})

add_library(webwrap STATIC
    src/webwrap.c
)

if(APPLE)
    target_sources(webwrap
        PRIVATE
            src/platform/apple/ww_apple_http.m
    )

    target_link_libraries(webwrap
        PRIVATE
            "-framework Foundation"
    )
endif()

add_library(webwrap::webwrap ALIAS webwrap)

target_include_directories(webwrap
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_definitions(webwrap
    PUBLIC
        WEBWRAP_VERSION_MAJOR=${PROJECT_VERSION_MAJOR}
        WEBWRAP_VERSION_MINOR=${PROJECT_VERSION_MINOR}
        WEBWRAP_VERSION_PATCH=${PROJECT_VERSION_PATCH}
)

add_executable(webwrap_cli
    src/cli/main.c
)

target_link_libraries(webwrap_cli
    PRIVATE
        webwrap
)

set_target_properties(webwrap_cli PROPERTIES OUTPUT_NAME webwrap)

if(WEBWRAP_BUILD_TESTS)
    find_package(Threads REQUIRED)
    find_package(GTest CONFIG QUIET)

    if(NOT GTest_FOUND)
        include(FetchContent)

        set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
        FetchContent_Declare(
            googletest
            URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.zip
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        )
        FetchContent_MakeAvailable(googletest)
    endif()

    add_executable(webwrap_tests
        tests/test_sum.cpp
    )

    if(APPLE)
        target_sources(webwrap_tests
            PRIVATE
                tests/test_macos_get.mm
        )
    endif()

    target_link_libraries(webwrap_tests
        PRIVATE
            webwrap
            GTest::gtest_main
            Threads::Threads
    )

    if(APPLE)
        target_link_libraries(webwrap_tests
            PRIVATE
                "-framework Foundation"
        )
    endif()

    include(GoogleTest)
    gtest_discover_tests(webwrap_tests)
endif()
