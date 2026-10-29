cmake_minimum_required(VERSION 3.18)
project(fbvr_frames LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

# The shared library Kotlin (through JNI) and Dart (through dart:ffi) both load. It holds the ring
# of native frame slots and the pixel conversions.
add_library(fbvr_frames SHARED
    frame_ring.cpp
    yuv_convert.cpp
    jni_bridge.cpp)

target_compile_options(fbvr_frames PRIVATE -O3 -Wall -Wextra)

# Android 15 devices can use 16 KB memory pages; the library has to be aligned for them.
target_link_options(fbvr_frames PRIVATE -Wl,-z,max-page-size=16384)
