cmake_minimum_required(VERSION 3.18)
project(zimffi CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# LIBZIM_DIR is the extracted prebuilt libzim Android tree (passed by build_zim.sh).
if(NOT DEFINED LIBZIM_DIR)
  message(FATAL_ERROR "LIBZIM_DIR must be set to the prebuilt libzim Android dir")
endif()

add_library(zimffi SHARED zimffi.cpp)
target_include_directories(zimffi PRIVATE "${LIBZIM_DIR}/include")
# Link against the prebuilt libzim.so (Xapian/zstd/lzma/ICU are static inside it).
target_link_libraries(zimffi "${LIBZIM_DIR}/lib/aarch64-linux-android/libzim.so")
