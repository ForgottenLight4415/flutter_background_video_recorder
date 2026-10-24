package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VideoSizeTest {
    private fun d(w: Int, h: Int) = VideoDimension(w, h)

    @Test
    fun prefersLargest1080pSixteenByNine() {
        val choices = listOf(d(3840, 2160), d(1920, 1080), d(1280, 720), d(1440, 1080), d(640, 480))
        assertEquals(d(1920, 1080), chooseVideoDimension(choices))
    }

    @Test
    fun prefersSixteenByNineOverLargerFourByThree() {
        val choices = listOf(d(1440, 1080), d(1280, 720), d(640, 480))
        assertEquals(d(1280, 720), chooseVideoDimension(choices))
    }

    @Test
    fun fallsBackToLargestFittingWhenNoSixteenByNine() {
        val choices = listOf(d(1440, 1080), d(640, 480), d(3840, 2160))
        assertEquals(d(1440, 1080), chooseVideoDimension(choices))
    }

    @Test
    fun fallsBackToSmallestWhenEverythingIsLarger() {
        val choices = listOf(d(3840, 2160), d(2560, 1440))
        assertEquals(d(2560, 1440), chooseVideoDimension(choices))
    }

    @Test
    fun ignoresPortraitSizesWhenLandscapeExists() {
        val choices = listOf(d(1080, 1920), d(1280, 720))
        assertEquals(d(1280, 720), chooseVideoDimension(choices))
    }

    @Test
    fun emptyChoicesGiveNull() {
        assertNull(chooseVideoDimension(emptyList()))
    }

    @Test
    fun orientationHintForBackCamera() {
        assertEquals(90, videoOrientationHint(90, 0, frontFacing = false))
        assertEquals(0, videoOrientationHint(90, 90, frontFacing = false))
        assertEquals(180, videoOrientationHint(90, 270, frontFacing = false))
    }

    @Test
    fun orientationHintForFrontCamera() {
        assertEquals(270, videoOrientationHint(270, 0, frontFacing = true))
        assertEquals(0, videoOrientationHint(270, 90, frontFacing = true))
        assertEquals(180, videoOrientationHint(270, 270, frontFacing = true))
    }

    @Test
    fun theDisplayCorrectionAloneIsWhatIsLeftAfterTheSensorTurn() {
        // The preview's relay only applies this part; the sensor part is in the texture matrix.
        assertEquals(0, videoOrientationHint(0, 0, frontFacing = false))
        assertEquals(270, videoOrientationHint(0, 90, frontFacing = false))
        assertEquals(90, videoOrientationHint(0, 90, frontFacing = true))
    }
}

class PreviewSizeTest {
    private fun d(w: Int, h: Int) = VideoDimension(w, h)

    @Test
    fun previewMatchesTheVideoAspectRatioAndStaysAtOrBelow720p() {
        val sizes = listOf(d(1920, 1080), d(1280, 720), d(1280, 960), d(640, 480), d(1440, 1080))
        assertEquals(d(1280, 720), choosePreviewDimension(sizes, 16.0 / 9.0))
        assertEquals(d(640, 480), choosePreviewDimension(listOf(d(1920, 1440), d(640, 480)), 4.0 / 3.0))
    }

    @Test
    fun theLargestMatchingSizeWins() {
        val sizes = listOf(d(1280, 720), d(960, 540), d(640, 360))
        assertEquals(d(1280, 720), choosePreviewDimension(sizes, 16.0 / 9.0))
    }

    @Test
    fun withoutAnAspectRatioSixteenByNineIsPreferred() {
        val sizes = listOf(d(640, 480), d(1280, 720))
        assertEquals(d(1280, 720), choosePreviewDimension(sizes, null))
    }

    @Test
    fun anAspectRatioWithNoMatchFallsBackToTheClosest() {
        val sizes = listOf(d(1280, 720), d(640, 480))
        // 1:1 is closer to 4:3 than to 16:9.
        assertEquals(d(640, 480), choosePreviewDimension(sizes, 1.0))
    }

    @Test
    fun whenEverythingIsTooBigTheSmallestIsUsed() {
        assertEquals(d(1920, 1080), choosePreviewDimension(listOf(d(3840, 2160), d(1920, 1080)), 16.0 / 9.0))
    }

    @Test
    fun noSizesGiveNull() {
        assertNull(choosePreviewDimension(emptyList(), 16.0 / 9.0))
    }

    @Test
    fun uprightSizeSwapsForQuarterTurns() {
        assertEquals(d(1280, 720), uprightPreviewSize(d(1280, 720), 0))
        assertEquals(d(1280, 720), uprightPreviewSize(d(1280, 720), 180))
        assertEquals(d(720, 1280), uprightPreviewSize(d(1280, 720), 90))
        assertEquals(d(720, 1280), uprightPreviewSize(d(1280, 720), 270))
    }
}
