cmake_minimum_required(VERSION 3.10)
project(CactusFlutterFFI LANGUAGES CXX)

# Builds the Android arm64-v8a `libcactus.so` that exports the Cactus C FFI
# symbols (cactus_init, cactus_complete, ...) used by the Dart bindings in
# lib/cactus.dart.
#
# This is intentionally NOT the JNI library produced by android/build.sh: that
# one hides the C FFI symbols (-fvisibility=hidden + -Wl,--exclude-libs,ALL) and
# only exposes Java_com_cactus_* entry points for the Kotlin SDK. Here we
# whole-archive the engine so the FFI exports survive.

set(CMAKE_BUILD_TYPE Release CACHE STRING "")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

if(NOT ${ANDROID_ABI} STREQUAL "arm64-v8a")
    message(FATAL_ERROR "Unsupported Android ABI: ${ANDROID_ABI}. Cactus only supports arm64-v8a.")
endif()

# This file lives at flutter/example/native -> repo root is three levels up.
get_filename_component(CACTUS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)

set(CACTUS_MBEDTLS_ROOT "${CACTUS_ROOT}/android/mbedtls/${ANDROID_ABI}")
if(NOT EXISTS "${CACTUS_MBEDTLS_ROOT}")
    set(CACTUS_MBEDTLS_ROOT "${CACTUS_ROOT}/libs/mbedtls/android/${ANDROID_ABI}")
endif()

set(CACTUS_CURL_A "${CACTUS_ROOT}/cactus-engine/libs/curl/android/${ANDROID_ABI}/libcurl.a")

# Build the engine/graph/kernels static libraries.
if(NOT TARGET cactus_engine)
    add_subdirectory(${CACTUS_ROOT}/cactus ${CMAKE_CURRENT_BINARY_DIR}/cactus)
endif()

# Note: the `cactus` name is taken by a utility target from cactus/CMakeLists.txt,
# so the shared-library target is `cactus_ffi` with output name `cactus`
# (-> libcactus.so).
# usearch (HNSW ANN) C binding, compiled directly into the shared lib so its
# extern "C" symbols (usearch_*) are exported for Dart FFI. Header-only C++ core.
set(USEARCH_DIR ${CMAKE_CURRENT_SOURCE_DIR}/usearch)
# Placeholder translation unit: the cactus_ffi symbols come from the
# whole-archived engine libs + usearch's lib.cpp, but a SHARED library still
# needs at least one source. The engine subproject only writes this stub when it
# is the top-level project (CMAKE_SOURCE_DIR guard), so create it here too — this
# is the top-level CMakeLists for the standalone FFI build.
file(WRITE ${CMAKE_BINARY_DIR}/stub.cpp "")
add_library(cactus_ffi SHARED
    ${CMAKE_BINARY_DIR}/stub.cpp
    ${USEARCH_DIR}/lib.cpp
)
target_include_directories(cactus_ffi PRIVATE ${USEARCH_DIR} ${USEARCH_DIR}/include)
target_compile_definitions(cactus_ffi PRIVATE USEARCH_USE_SIMSIMD=0 USEARCH_USE_FP16LIB=0)
set_target_properties(cactus_ffi PROPERTIES
    OUTPUT_NAME cactus
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)
add_dependencies(cactus_ffi cactus_engine cactus_graph cactus_kernels)

# Force-load the engine archives so the exported (visibility=default) C FFI
# symbols are kept in the shared object's dynamic symbol table.
target_link_options(cactus_ffi PRIVATE
    -Wl,--whole-archive
    $<TARGET_FILE:cactus_engine>
    $<TARGET_FILE:cactus_graph>
    $<TARGET_FILE:cactus_kernels>
    -Wl,--no-whole-archive
    -Wl,-z,max-page-size=16384
)

# libcurl (TLS via mbedtls) is referenced by the engine; the platform log and
# android libs are needed by the engine too.
find_library(LOG_LIB log)
target_link_libraries(cactus_ffi PRIVATE
    "${CACTUS_CURL_A}"
    "${CACTUS_MBEDTLS_ROOT}/lib/libmbedtls.a"
    "${CACTUS_MBEDTLS_ROOT}/lib/libmbedx509.a"
    "${CACTUS_MBEDTLS_ROOT}/lib/libmbedcrypto.a"
    ${LOG_LIB}
    android
)
