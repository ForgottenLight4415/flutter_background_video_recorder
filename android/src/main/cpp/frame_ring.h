// A ring of fixed-size slots in native memory that carries camera frames from the producer
// (Kotlin, through JNI) to the app (Dart, through dart:ffi) without copying the pixels again.
//
// No Android or JNI headers here, so that the same code is tested on the host.
#pragma once

#include <cstddef>
#include <cstdint>

namespace fbvr {

// Rings are handled by id, never by pointer, so that a late call for a ring that was freed is
// ignored instead of touching freed memory.
using RingId = int64_t;

// Creates a ring of |slot_count| slots of |capacity| bytes. Returns 0 on failure.
RingId ring_create(int slot_count, size_t capacity);

// Takes a free slot for writing and returns its index (the slot starts with one reference, the
// producer's), or -1 when every slot is in use, which is counted as a dropped frame. Only the
// producer thread calls this.
int ring_acquire(RingId id);

// The start of the slot's memory, or null for an unknown ring or slot.
uint8_t* ring_slot_data(RingId id, int slot);

size_t ring_capacity(RingId id);

// Adds a reference for the Dart side and remembers that Dart holds the slot.
void ring_retain_for_dart(RingId id, int slot);

// Drops a reference. The slot is free again when none is left.
void ring_release(RingId id, int slot);

// Dart's release. Ignored when Dart does not hold the slot (released twice, or abandoned), or when
// the ring is gone.
void ring_release_by_dart(RingId id, int slot);

// Releases every slot of every ring that Dart still holds, for when the Dart side is gone.
void ring_abandon_all_dart();

// No more slots will be acquired. The memory is freed once every slot has been released.
void ring_close(RingId id);

// The number of frames that found no free slot, since the ring was created. -1 for an unknown ring.
int64_t ring_dropped(RingId id);

// The number of rings that exist, for tests and leak checks.
int ring_live_count();

}  // namespace fbvr

// For dart:ffi. Exported by name from the shared library.
extern "C" __attribute__((visibility("default"))) void fbvr_slot_release(int64_t ring_id, int32_t slot);
