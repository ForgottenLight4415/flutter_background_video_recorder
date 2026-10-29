import 'dart:ffi';
import 'dart:typed_data';

import 'native_frames.dart';

/// Reads frames straight out of the native memory of `libfbvr_frames.so` and gives their slots back
/// by calling into it. The library is the one the plugin's Android code loaded, so both sides work
/// on the same rings.
class FfiFrameMemory implements NativeFrameMemory {
  /// Opens the library when first needed. [libraryPath] is for tests, which load a build made for
  /// the host machine.
  FfiFrameMemory({String libraryPath = 'libfbvr_frames.so'})
    : _libraryPath = libraryPath;

  final String _libraryPath;

  late final DynamicLibrary _library = DynamicLibrary.open(_libraryPath);

  late final void Function(int ring, int slot)
  _release = _library.lookupFunction<
    Void Function(Int64, Int32),
    void Function(int, int)
  >(
    'fbvr_slot_release',
    // It only flips a few atomics, never calls back into Dart, so the cheap call is safe.
    isLeaf: true,
  );

  @override
  Uint8List view(int address, int length) =>
      Pointer<Uint8>.fromAddress(address).asTypedList(length);

  @override
  void release(int ringId, int slot) => _release(ringId, slot);
}
