package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CameraSelectionTest {
    private fun d(w: Int, h: Int) = VideoDimension(w, h)

    @Test
    fun zoomRangeLimitsTheRatio() {
        val range = ZoomRange(0.6f, 10f)
        assertEquals(0.6f, range.clamp(0.1f), 0f)
        assertEquals(10f, range.clamp(50f), 0f)
        assertEquals(2.5f, range.clamp(2.5f), 0f)
    }

    @Test
    fun zoomRangeTreatsNotANumberAsNormalView() {
        assertEquals(1f, ZoomRange(0.6f, 10f).clamp(Float.NaN), 0f)
        assertEquals(2f, ZoomRange(2f, 5f).clamp(Float.NaN), 0f)
    }

    @Test
    fun aCameraThatCannotZoomStaysAtOne() {
        assertEquals(1f, ZoomRange.NONE.clamp(3f), 0f)
        assertEquals(1f, ZoomRange.NONE.clamp(0.5f), 0f)
    }

    @Test
    fun equivalentFocalLengthScalesByTheSensorDiagonal() {
        // A full-frame sensor (36 x 24 mm) leaves the focal length as it is.
        assertEquals(50f, equivalentFocalLength(50f, 36f, 24f)!!, 0.1f)
        // A sensor with half the diagonal doubles it.
        assertEquals(10f, equivalentFocalLength(5f, 18f, 12f)!!, 0.1f)
    }

    @Test
    fun equivalentFocalLengthIsUnknownForUnusableNumbers() {
        assertNull(equivalentFocalLength(0f, 6f, 4f))
        assertNull(equivalentFocalLength(5f, 0f, 0f))
    }

    @Test
    fun defaultFrameSizeIsTheLargestUpTo720p() {
        val sizes = listOf(d(4000, 3000), d(1920, 1080), d(1280, 720), d(640, 480))
        assertEquals(d(1280, 720), chooseFrameDimension(sizes, null))
    }

    @Test
    fun anExactFrameSizeIsUsedWhenOffered() {
        val sizes = listOf(d(1920, 1080), d(1280, 720), d(640, 480))
        assertEquals(d(640, 480), chooseFrameDimension(sizes, d(640, 480)))
    }

    @Test
    fun theClosestAspectRatioWinsOverTheClosestSize() {
        val sizes = listOf(d(1920, 1080), d(1600, 1200), d(640, 480))
        // 4:3 asked for at a size nobody offers: the 4:3 sizes win, then the nearer pixel count.
        assertEquals(d(1600, 1200), chooseFrameDimension(sizes, d(1500, 1125)))
    }

    @Test
    fun aPortraitRequestIsReadAsLandscape() {
        val sizes = listOf(d(1920, 1080), d(1280, 720))
        assertEquals(d(1280, 720), chooseFrameDimension(sizes, d(720, 1280)))
    }

    @Test
    fun noFrameSizeWhenTheCameraOffersNone() {
        assertNull(chooseFrameDimension(emptyList(), null))
        assertNull(chooseFrameDimension(emptyList(), d(640, 480)))
    }

    @Test
    fun cameraChoiceKeepsTheIdAndTheFacing() {
        val choice = CameraChoice("3", frontFacing = true)
        assertNotNull(choice.cameraId)
        assertEquals(CameraChoice("3", true), choice)
    }
}
