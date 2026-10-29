package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class RawFrameConverterTest {
    private fun plane(vararg bytes: Int, rowStride: Int, pixelStride: Int) =
        PlaneData(ByteArray(bytes.size) { bytes[it].toByte() }, rowStride, pixelStride)

    @Test
    fun nv21InterleavesVBeforeU() {
        // 2 x 2 picture: four luma samples and one chroma sample of each kind.
        val y = plane(10, 20, 30, 40, rowStride = 2, pixelStride = 1)
        val u = plane(100, rowStride = 1, pixelStride = 1)
        val v = plane(200, rowStride = 1, pixelStride = 1)
        val nv21 = RawFrameConverter.yuvToNv21(y, u, v, 2, 2)
        assertArrayEquals(byteArrayOf(10, 20, 30, 40, 200.toByte(), 100), nv21)
    }

    @Test
    fun nv21SkipsRowPadding() {
        // Rows of 4 bytes carry only 2 pixels; the padding must not end up in the picture.
        val y = plane(1, 2, 99, 99, 3, 4, 99, 99, rowStride = 4, pixelStride = 1)
        val u = plane(5, rowStride = 1, pixelStride = 1)
        val v = plane(6, rowStride = 1, pixelStride = 1)
        val nv21 = RawFrameConverter.yuvToNv21(y, u, v, 2, 2)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 6, 5), nv21)
    }

    @Test
    fun nv21ReadsInterleavedChromaPlanes() {
        // The camera often hands over U and V as two views of one interleaved buffer (pixel stride 2).
        val y = plane(1, 2, 3, 4, rowStride = 2, pixelStride = 1)
        val u = plane(50, 60, rowStride = 2, pixelStride = 2) // only the first byte is a sample
        val v = plane(70, 80, rowStride = 2, pixelStride = 2)
        val nv21 = RawFrameConverter.yuvToNv21(y, u, v, 2, 2)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 70, 50), nv21)
    }

    @Test
    fun nv21OfAFourByTwoPictureUsesTwoChromaSamplesPerRow() {
        val y = plane(1, 2, 3, 4, 5, 6, 7, 8, rowStride = 4, pixelStride = 1)
        val u = plane(11, 12, rowStride = 2, pixelStride = 1)
        val v = plane(21, 22, rowStride = 2, pixelStride = 1)
        val nv21 = RawFrameConverter.yuvToNv21(y, u, v, 4, 2)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 21, 11, 22, 12), nv21)
    }

    @Test
    fun rgbaOfAGreyPictureKeepsTheLumaInEveryChannel() {
        val y = plane(0, 128, 255, 64, rowStride = 2, pixelStride = 1)
        val u = plane(128, rowStride = 1, pixelStride = 1)
        val v = plane(128, rowStride = 1, pixelStride = 1)
        val rgba = RawFrameConverter.yuvToRgba(y, u, v, 2, 2)
        val expectedLuma = intArrayOf(0, 128, 255, 64)
        for (pixel in 0 until 4) {
            for (channel in 0 until 3) {
                assertEquals(expectedLuma[pixel], rgba[pixel * 4 + channel].toInt() and 0xFF)
            }
            assertEquals(255, rgba[pixel * 4 + 3].toInt() and 0xFF)
        }
    }

    @Test
    fun rgbaShowsStrongRedForHighV() {
        val y = plane(128, 128, 128, 128, rowStride = 2, pixelStride = 1)
        val u = plane(128, rowStride = 1, pixelStride = 1)
        val v = plane(255, rowStride = 1, pixelStride = 1)
        val rgba = RawFrameConverter.yuvToRgba(y, u, v, 2, 2)
        val red = rgba[0].toInt() and 0xFF
        val green = rgba[1].toInt() and 0xFF
        val blue = rgba[2].toInt() and 0xFF
        assert(red > 200) { "red was $red" }
        assert(green < 100) { "green was $green" }
        assertEquals(128, blue)
    }

    @Test
    fun rgbaIsClampedToTheByteRange() {
        val y = plane(255, 255, 0, 0, rowStride = 2, pixelStride = 1)
        val u = plane(255, rowStride = 1, pixelStride = 1)
        val v = plane(255, rowStride = 1, pixelStride = 1)
        val rgba = RawFrameConverter.yuvToRgba(y, u, v, 2, 2)
        assertEquals(255, rgba[0].toInt() and 0xFF) // red above 255 stays 255
        assertEquals(255, rgba[2].toInt() and 0xFF) // blue above 255 stays 255
        assertEquals(0, rgba[4 * 2 + 1].toInt() and 0xFF) // green below 0 stays 0
    }
}
