package com.lightsoftware.flutter_background_video_recorder.plugin

import java.nio.ByteBuffer

/**
 * The functions of `libfbvr_frames.so` that Kotlin calls. The library is registered against this
 * class in `JNI_OnLoad` (see `jni_bridge.cpp`), so the names and signatures here must match the
 * table there. Rings are handled by id: a call for a ring that is gone is ignored.
 */
internal object FrameRingJni {
    @Volatile
    var isLoaded = false
        private set

    /** Loads the library packaged with the plugin. Throws [UnsatisfiedLinkError] if it is missing. */
    @Synchronized
    fun load() {
        if (isLoaded) return
        System.loadLibrary("fbvr_frames")
        isLoaded = true
    }

    /** Loads a build of the library for the machine running the unit tests. */
    @Synchronized
    fun loadFrom(path: String) {
        if (isLoaded) return
        System.load(path)
        isLoaded = true
    }

    /** Releases what the Dart side still holds, for when it is gone. Does nothing if nothing was loaded. */
    fun abandonAllDartIfLoaded() {
        if (isLoaded) nativeAbandonAllDart()
    }

    @JvmStatic external fun nativeCreate(slots: Int, capacity: Long): Long

    @JvmStatic external fun nativeAcquire(ring: Long): Int

    @JvmStatic external fun nativeSlotAddress(ring: Long, slot: Int): Long

    @JvmStatic external fun nativeCopyBuffer(ring: Long, slot: Int, dstOffset: Int, src: ByteBuffer, srcOffset: Int, length: Int): Boolean

    @JvmStatic external fun nativeCopyBytes(ring: Long, slot: Int, dstOffset: Int, src: ByteArray, length: Int): Boolean

    @JvmStatic external fun nativeYuvToRgba(
        ring: Long,
        slot: Int,
        dstOffset: Int,
        y: ByteBuffer,
        yRowStride: Int,
        yPixelStride: Int,
        u: ByteBuffer,
        uRowStride: Int,
        uPixelStride: Int,
        v: ByteBuffer,
        vRowStride: Int,
        vPixelStride: Int,
        width: Int,
        height: Int,
    ): Boolean

    @JvmStatic external fun nativeYuvToNv21(
        y: ByteBuffer,
        yRowStride: Int,
        yPixelStride: Int,
        u: ByteBuffer,
        uRowStride: Int,
        uPixelStride: Int,
        v: ByteBuffer,
        vRowStride: Int,
        vPixelStride: Int,
        width: Int,
        height: Int,
        out: ByteArray,
    ): Boolean

    @JvmStatic external fun nativeRetainForDart(ring: Long, slot: Int)

    @JvmStatic external fun nativeRelease(ring: Long, slot: Int)

    @JvmStatic external fun nativeAbandonAllDart()

    @JvmStatic external fun nativeClose(ring: Long)

    @JvmStatic external fun nativeDropped(ring: Long): Long

    @JvmStatic external fun nativeLiveRings(): Int
}
