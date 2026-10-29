package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.nio.ByteBuffer
import java.util.Random

/**
 * Tests the JNI layer against a build of the native library for this machine. Skipped unless
 * FBVR_HOST_LIB names one: `scripts/test_native.sh --jni` builds it and prints the command.
 */
class FrameRingJniTest {
    @Before
    fun loadLibrary() {
        val path = System.getProperty("fbvr.host.lib")
        assumeTrue("FBVR_HOST_LIB is not set, skipping the JNI tests", path != null)
        FrameRingJni.loadFrom(path!!)
    }

    private val unsafe: Any by lazy {
        Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)!!
    }
    private val getByte by lazy { Class.forName("sun.misc.Unsafe").getMethod("getByte", java.lang.Long.TYPE) }

    private fun unsafeGetByte(address: Long): Byte = getByte.invoke(unsafe, address) as Byte

    /** Reads native memory, for checking what the library wrote. */
    private fun read(address: Long, offset: Int, length: Int) =
        ByteArray(length) { unsafeGetByte(address + offset + it) }

    private fun direct(vararg bytes: Int): ByteBuffer =
        ByteBuffer.allocateDirect(bytes.size).apply {
            bytes.forEach { put(it.toByte()) }
            flip()
        }

    private fun directOf(array: ByteArray): ByteBuffer =
        ByteBuffer.allocateDirect(array.size).apply {
            put(array)
            flip()
        }

    private fun ring(slots: Int = 2, capacity: Long = 4096): FrameRing =
        FrameRing.create(slots, capacity)!!

    @Test
    fun aSlotIsWritableMemoryOfTheRequestedSize() {
        val ring = ring()
        val lease = ring.acquire()!!
        assertTrue(lease.address != 0L)
        assertTrue(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 0, direct(1, 2, 3, 4), 0, 4))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), read(lease.address, 0, 4))
        lease.release()
        ring.close()
    }

    @Test
    fun copyBufferWritesAtTheOffsetFromTheSourceOffset() {
        val ring = ring()
        val lease = ring.acquire()!!
        assertTrue(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 100, direct(9, 8, 7, 6, 5), 1, 3))
        assertArrayEquals(byteArrayOf(8, 7, 6), read(lease.address, 100, 3))
        lease.release()
        ring.close()
    }

    @Test
    fun copyBufferRefusesWhatDoesNotFit() {
        val ring = ring(capacity = 128)
        val lease = ring.acquire()!!
        val source = direct(1, 2, 3, 4)
        // Past the end of the slot, past the end of the source, and negative offsets.
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 126, source, 0, 4))
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 0, source, 2, 4))
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, -1, source, 0, 4))
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 0, source, -1, 4))
        // A buffer that is not direct has no address to copy from.
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 0, ByteBuffer.allocate(4), 0, 4))
        // The last byte that does fit.
        assertTrue(FrameRingJni.nativeCopyBuffer(ring.id, lease.slot, 124, source, 0, 4))
        lease.release()
        ring.close()
    }

    @Test
    fun copyBytesWritesAnArray() {
        val ring = ring(capacity = 128)
        val lease = ring.acquire()!!
        assertTrue(FrameRingJni.nativeCopyBytes(ring.id, lease.slot, 8, byteArrayOf(5, 6, 7), 3))
        assertArrayEquals(byteArrayOf(5, 6, 7), read(lease.address, 8, 3))
        assertFalse(FrameRingJni.nativeCopyBytes(ring.id, lease.slot, 0, byteArrayOf(1), 2))
        assertFalse(FrameRingJni.nativeCopyBytes(ring.id, lease.slot, 127, byteArrayOf(1, 2), 2))
        lease.release()
        ring.close()
    }

    /** Planes with row padding and, for the colours, the interleaved layout many cameras use. */
    private class Picture(val width: Int, val height: Int, interleavedChroma: Boolean, seed: Long) {
        val chromaWidth = (width + 1) / 2
        val chromaHeight = (height + 1) / 2
        val yRow = width + 6
        val chromaPixel = if (interleavedChroma) 2 else 1
        val chromaRow = chromaWidth * chromaPixel + 4
        val y = ByteArray(yRow * height).also { Random(seed).nextBytes(it) }
        val u = ByteArray(chromaRow * chromaHeight).also { Random(seed + 1).nextBytes(it) }
        val v = ByteArray(chromaRow * chromaHeight).also { Random(seed + 2).nextBytes(it) }
        val referenceY = PlaneData(y, yRow, 1)
        val referenceU = PlaneData(u, chromaRow, chromaPixel)
        val referenceV = PlaneData(v, chromaRow, chromaPixel)
    }

    @Test
    fun nativeRgbaMatchesTheReferenceConversion() {
        for ((width, height, interleaved) in listOf(Triple(16, 8, false), Triple(33, 17, true), Triple(2, 2, true))) {
            val picture = Picture(width, height, interleaved, seed = width.toLong())
            val ring = ring(capacity = width * height * 4L)
            val lease = ring.acquire()!!
            val ok = FrameRingJni.nativeYuvToRgba(
                ring.id, lease.slot, 0,
                directOf(picture.y), picture.yRow, 1,
                directOf(picture.u), picture.chromaRow, picture.chromaPixel,
                directOf(picture.v), picture.chromaRow, picture.chromaPixel,
                width, height,
            )
            assertTrue(ok)
            val expected = RawFrameConverter.yuvToRgba(picture.referenceY, picture.referenceU, picture.referenceV, width, height)
            assertArrayEquals("${width}x$height", expected, read(lease.address, 0, expected.size))
            lease.release()
            ring.close()
        }
    }

    @Test
    fun nativeNv21MatchesTheReferenceConversion() {
        for ((width, height, interleaved) in listOf(Triple(16, 8, false), Triple(33, 17, true))) {
            val picture = Picture(width, height, interleaved, seed = 100L + width)
            val expected = RawFrameConverter.yuvToNv21(picture.referenceY, picture.referenceU, picture.referenceV, width, height)
            val out = ByteArray(expected.size)
            val ok = FrameRingJni.nativeYuvToNv21(
                directOf(picture.y), picture.yRow, 1,
                directOf(picture.u), picture.chromaRow, picture.chromaPixel,
                directOf(picture.v), picture.chromaRow, picture.chromaPixel,
                width, height, out,
            )
            assertTrue(ok)
            assertArrayEquals("${width}x$height", expected, out)
        }
    }

    @Test
    fun conversionsRefuseBuffersThatAreTooSmall() {
        val picture = Picture(16, 8, false, seed = 5)
        val ring = ring(capacity = 16 * 8 * 4)
        val lease = ring.acquire()!!
        val shortLuma = directOf(picture.y.copyOf(20))
        assertFalse(
            FrameRingJni.nativeYuvToRgba(
                ring.id, lease.slot, 0,
                shortLuma, picture.yRow, 1,
                directOf(picture.u), picture.chromaRow, 1,
                directOf(picture.v), picture.chromaRow, 1,
                16, 8,
            ),
        )
        // The destination must hold width * height * 4 bytes after the offset.
        assertFalse(
            FrameRingJni.nativeYuvToRgba(
                ring.id, lease.slot, 4,
                directOf(picture.y), picture.yRow, 1,
                directOf(picture.u), picture.chromaRow, 1,
                directOf(picture.v), picture.chromaRow, 1,
                16, 8,
            ),
        )
        assertFalse(
            FrameRingJni.nativeYuvToNv21(
                directOf(picture.y), picture.yRow, 1,
                directOf(picture.u), picture.chromaRow, 1,
                directOf(picture.v), picture.chromaRow, 1,
                16, 8, ByteArray(10),
            ),
        )
        lease.release()
        ring.close()
    }

    @Test
    fun slotsRunOutAndComeBack() {
        val ring = ring(slots = 2)
        val first = ring.acquire()!!
        val second = ring.acquire()!!
        assertTrue(first.slot != second.slot)
        assertNull(ring.acquire())
        assertNull(ring.acquire())
        assertEquals(2L, ring.dropped)
        second.release()
        assertNotNull(ring.acquire())
        first.release()
        ring.close()
    }

    @Test
    fun theDartSideKeepsASlotUntilItIsAbandoned() {
        val ring = ring(slots = 1)
        val lease = ring.acquire()!!
        lease.retainForDart()
        lease.release() // the hub is done
        assertNull(ring.acquire()) // Dart still holds it
        FrameRingJni.nativeAbandonAllDart()
        val again = ring.acquire()
        assertNotNull(again)
        again!!.release()
        ring.close()
    }

    @Test
    fun aClosedRingIsFreedOnceItsSlotsAreReleased() {
        val before = FrameRingJni.nativeLiveRings()
        val ring = ring(slots = 2)
        val lease = ring.acquire()!!
        assertEquals(before + 1, FrameRingJni.nativeLiveRings())
        ring.close()
        // The slot in use keeps the memory alive, and nothing new is handed out.
        assertEquals(before + 1, FrameRingJni.nativeLiveRings())
        assertNull(ring.acquire())
        lease.release()
        assertEquals(before, FrameRingJni.nativeLiveRings())
    }

    @Test
    fun callsForARingThatIsGoneAreIgnored() {
        val ring = ring()
        val lease = ring.acquire()!!
        lease.release()
        ring.close()
        lease.release()
        lease.retainForDart()
        ring.close()
        assertNull(ring.acquire())
        assertEquals(0L, ring.dropped)
        assertFalse(FrameRingJni.nativeCopyBuffer(ring.id, 0, 0, direct(1), 0, 1))
    }

    @Test
    fun invalidRingsAreRefused() {
        assertNull(FrameRing.create(0, 1024))
        assertNull(FrameRing.create(2, 0))
    }
}
