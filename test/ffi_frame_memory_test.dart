import 'dart:io';

import 'package:flutter_background_video_recorder/src/ffi_frame_memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// Calls the real native library through dart:ffi. Needs a build of it for this machine:
/// `scripts/test_native.sh --jni` makes one, and FBVR_HOST_LIB names it.
void main() {
  final path = Platform.environment['FBVR_HOST_LIB'];

  test(
    'the release function is found and tolerates a ring that is gone',
    () {
      final memory = FfiFrameMemory(libraryPath: path!);
      // No such ring: ignored, as the Dart side may release after the session ended.
      memory.release(987654321, 0);
      memory.release(987654321, 7);
    },
    skip: path == null ? 'FBVR_HOST_LIB is not set' : null,
  );
}
