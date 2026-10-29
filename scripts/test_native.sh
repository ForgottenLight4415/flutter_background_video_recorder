#!/usr/bin/env bash
# Builds and runs the host tests of the native frame ring and pixel conversions.
#
#   scripts/test_native.sh          the C++ tests
#   scripts/test_native.sh --jni    also builds the library for this machine, for the JNI test in
#                                   the Kotlin unit tests (needs a JDK; prints the Gradle command)
#
# Set CXX to pick the compiler.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cpp="$root/android/src/main/cpp"
out="${TMPDIR:-/tmp}/fbvr_native_test"
mkdir -p "$out"
cxx="${CXX:-c++}"

flags=(-std=c++17 -O1 -g -Wall -Wextra -pthread)
if [[ "${SANITIZE:-}" == "1" ]]; then flags+=(-fsanitize=address,undefined); fi

"$cxx" "${flags[@]}" "$cpp/tests/ring_test.cpp" "$cpp/frame_ring.cpp" "$cpp/yuv_convert.cpp" -o "$out/ring_test"
"$out/ring_test"

if [[ "${1:-}" == "--jni" ]]; then
  java_home="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || true)}"
  [[ -n "$java_home" ]] || { echo "JAVA_HOME is not set" >&2; exit 1; }
  case "$(uname -s)" in
    Darwin) include=darwin; ext=dylib ;;
    *) include=linux; ext=so ;;
  esac
  lib="$out/libfbvr_frames.$ext"
  "$cxx" -std=c++17 -O2 -shared -fPIC -fvisibility=hidden -pthread \
    -I"$java_home/include" -I"$java_home/include/$include" \
    "$cpp/frame_ring.cpp" "$cpp/yuv_convert.cpp" "$cpp/jni_bridge.cpp" -o "$lib"
  echo "Built $lib. Run the JNI test with:"
  echo "  (cd example/android && FBVR_HOST_LIB=$lib ./gradlew :flutter_background_video_recorder:testDebugUnitTest)"
fi
