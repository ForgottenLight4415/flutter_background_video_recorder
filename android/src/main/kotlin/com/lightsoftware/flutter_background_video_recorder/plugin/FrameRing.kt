package com.lightsoftware.flutter_background_video_recorder.plugin

/** Holds and drops references on a slot. Separate from the JNI calls so that tests can count them. */
internal interface SlotOwner {
    fun retainForDart(ring: Long, slot: Int)

    fun release(ring: Long, slot: Int)
}

/** The slot references of the real native library. */
internal object JniSlotOwner : SlotOwner {
    override fun retainForDart(ring: Long, slot: Int) = FrameRingJni.nativeRetainForDart(ring, slot)

    override fun release(ring: Long, slot: Int) = FrameRingJni.nativeRelease(ring, slot)
}

/**
 * A claim on one slot of a [FrameRing]: while a reference is held, the slot's memory stays valid
 * and is not reused. The producer starts with one and hands it to the hub, which releases it after
 * the subscribers have seen the frame. The one subscriber that outlives that moment, the channel
 * forwarder, takes a reference for the Dart side ([retainForDart]); Dart gives it back through
 * `dart:ffi`. A subscriber that wants to keep a frame itself would have to do the same.
 */
internal class FrameLease(
    private val owner: SlotOwner,
    val ring: Long,
    val slot: Int,
    /** Where the slot's memory starts. */
    val address: Long,
) {
    /** For the Dart side, which releases the reference itself through `dart:ffi`. */
    fun retainForDart() = owner.retainForDart(ring, slot)

    fun release() = owner.release(ring, slot)
}

/** A ring of native memory slots that frames are written into. Only one thread acquires slots. */
internal class FrameRing private constructor(
    val id: Long,
    private val owner: SlotOwner,
) {
    /** A free slot, or null when all are in use. That counts as a dropped frame, see [dropped]. */
    fun acquire(): FrameLease? {
        val slot = FrameRingJni.nativeAcquire(id)
        if (slot < 0) return null
        return FrameLease(owner, id, slot, FrameRingJni.nativeSlotAddress(id, slot))
    }

    /** How many frames found no free slot. */
    val dropped: Long get() = FrameRingJni.nativeDropped(id).coerceAtLeast(0)

    /** No more slots are handed out. The memory is freed once every slot has been released. */
    fun close() = FrameRingJni.nativeClose(id)

    companion object {
        /** Null if the memory could not be allocated. The library must be loaded. */
        fun create(slots: Int, capacity: Long, owner: SlotOwner = JniSlotOwner): FrameRing? {
            val id = FrameRingJni.nativeCreate(slots, capacity)
            return if (id == 0L) null else FrameRing(id, owner)
        }
    }
}
