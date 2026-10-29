import 'dart:typed_data';

/// Where the pixels of a [RawFrame] live: native memory that the camera side writes into and the
/// app reads in place, without a copy.
///
/// The default implementation uses `dart:ffi`; tests and other platform implementations can
/// provide their own.
abstract class NativeFrameMemory {
  /// A view of [length] bytes of native memory starting at [address]. It is only valid while the
  /// frame it belongs to has not been released.
  Uint8List view(int address, int length);

  /// Gives the slot [slot] of the ring [ringId] back, so the camera side can reuse it.
  void release(int ringId, int slot);
}

/// A claim on one slot of native memory, given back exactly once.
class FrameSlot {
  /// The slot [slot] of the ring [ringId], which lives in native memory read through `memory`.
  FrameSlot(this._memory, this.ringId, this.slot);

  final NativeFrameMemory _memory;

  /// The ring the slot belongs to.
  final int ringId;

  /// The index of the slot in its ring.
  final int slot;

  bool _freed = false;

  /// Whether the slot has been given back.
  bool get isFreed => _freed;

  /// Gives the slot back. Does nothing the second time.
  void free() {
    if (_freed) return;
    _freed = true;
    _memory.release(ringId, slot);
  }
}
