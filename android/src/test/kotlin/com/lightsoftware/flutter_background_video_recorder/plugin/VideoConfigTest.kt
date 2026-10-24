package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class VideoConfigTest {
    private fun d(w: Int, h: Int) = VideoDimension(w, h)
    private fun mode(w: Int, h: Int, vararg fps: Int) = VideoMode(d(w, h), fps.toList())

    private val allCodecs = CodecAvailability(CodecSupport(true, true), CodecSupport(true, true))
    private val softwareHevc = CodecAvailability(CodecSupport(true, true), CodecSupport(true, false))
    private val noHevc = CodecAvailability(CodecSupport(true, true), CodecSupport(false, false))

    private val ranges = listOf(FpsRange(15, 30), FpsRange(30, 30), FpsRange(24, 24), FpsRange(60, 60))

    // region supportedFrameRates / buildModes / chooseAeRange

    @Test
    fun frameRatesNeedARangeEndingAtThem() {
        assertEquals(listOf(24, 30, 60), supportedFrameRates(60, 60, ranges))
        // 25 and 50 are not offered by the camera's ranges.
        assertEquals(listOf(30), supportedFrameRates(60, 60, listOf(FpsRange(15, 30))))
    }

    @Test
    fun frameRatesAreLimitedBySensorAndEncoder() {
        assertEquals(listOf(24, 30), supportedFrameRates(30, 60, ranges))
        assertEquals(listOf(24, 30), supportedFrameRates(60, 30, ranges))
    }

    @Test
    fun withoutRangesOnlyThirtyIsPromised() {
        assertEquals(listOf(30), supportedFrameRates(60, 60, emptyList()))
        assertEquals(emptyList<Int>(), supportedFrameRates(24, 60, emptyList()))
    }

    @Test
    fun modesAreLandscapeOnlyDistinctAndLargestFirst() {
        val modes = buildModes(
            sizes = listOf(d(1280, 720), d(1080, 1920), d(1920, 1080), d(1280, 720), d(3840, 2160)),
            sensorMaxFps = { if (it.width >= 3840) 30 else 60 },
            codecMaxFps = { 60 },
            aeRanges = ranges,
        )
        assertEquals(
            listOf(mode(3840, 2160, 24, 30), mode(1920, 1080, 24, 30, 60), mode(1280, 720, 24, 30, 60)),
            modes,
        )
    }

    @Test
    fun sizesThatCannotBeRecordedAreDropped() {
        val modes = buildModes(
            sizes = listOf(d(1920, 1080), d(7680, 4320)),
            sensorMaxFps = { 60 },
            codecMaxFps = { if (it.width > 4000) 0 else 60 },
            aeRanges = ranges,
        )
        assertEquals(listOf(d(1920, 1080)), modes.map { it.dimension })
    }

    @Test
    fun aeRangeEndsAtTheFrameRateAndPrefersTheSteadiest() {
        assertEquals(FpsRange(30, 30), chooseAeRange(ranges, 30))
        assertEquals(FpsRange(60, 60), chooseAeRange(ranges, 60))
        assertNull(chooseAeRange(ranges, 48))
    }

    // endregion

    // region chooseVideoConfig: resolution and frame rate

    private val typicalModes = listOf(
        mode(3840, 2160, 24, 30),
        mode(1920, 1080, 24, 30, 60),
        mode(1440, 1080, 24, 30),
        mode(1280, 720, 24, 30, 60),
        mode(640, 480, 30),
    )

    @Test
    fun defaultIs1080p60() {
        val result = chooseVideoConfig(VideoRequest(), typicalModes, allCodecs)
        assertEquals(d(1920, 1080), result.dimension)
        assertEquals(60, result.frameRate)
        assertEquals(EncoderCodec.H264, result.codec)
    }

    @Test
    fun defaultFallsBackTo1080p30() {
        val modes = listOf(mode(1920, 1080, 24, 30), mode(1280, 720, 24, 30, 60))
        val result = chooseVideoConfig(VideoRequest(), modes, allCodecs)
        assertEquals(d(1920, 1080), result.dimension)
        assertEquals(30, result.frameRate)
    }

    @Test
    fun defaultFallsBackToTheBestSizeUpTo1080pWhenThereIsNo1080p() {
        val modes = listOf(mode(3840, 2160, 30), mode(1280, 720, 30, 60), mode(640, 480, 30))
        val result = chooseVideoConfig(VideoRequest(), modes, allCodecs)
        assertEquals(d(1280, 720), result.dimension)
        assertEquals(60, result.frameRate)
    }

    @Test
    fun requestedFrameRateChoosesASizeThatSupportsIt() {
        val modes = listOf(mode(1920, 1080, 24, 30), mode(1280, 720, 24, 30, 60))
        val result = chooseVideoConfig(VideoRequest(frameRate = 60), modes, allCodecs)
        assertEquals(d(1280, 720), result.dimension)
        assertEquals(60, result.frameRate)
    }

    @Test
    fun explicitSizeUsesItsBestFrameRate() {
        val result = chooseVideoConfig(VideoRequest(width = 1280, height = 720), typicalModes, allCodecs)
        assertEquals(d(1280, 720), result.dimension)
        assertEquals(60, result.frameRate)

        val fourK = chooseVideoConfig(VideoRequest(width = 3840, height = 2160), typicalModes, allCodecs)
        assertEquals(30, fourK.frameRate)
    }

    @Test
    fun explicitSizeAndFrameRateAreHonoured() {
        val result = chooseVideoConfig(VideoRequest(width = 1920, height = 1080, frameRate = 24), typicalModes, allCodecs)
        assertEquals(d(1920, 1080), result.dimension)
        assertEquals(24, result.frameRate)
    }

    @Test
    fun portraitSizesAreAcceptedAndStoredLandscape() {
        val result = chooseVideoConfig(VideoRequest(width = 1080, height = 1920), typicalModes, allCodecs)
        assertEquals(d(1920, 1080), result.dimension)
    }

    @Test
    fun anUnsupportedExplicitSizeIsRefused() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(width = 2560, height = 1440), typicalModes, allCodecs)
        }
    }

    @Test
    fun anUnsupportedExplicitFrameRateIsRefused() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(width = 3840, height = 2160, frameRate = 60), typicalModes, allCodecs)
        }
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(frameRate = 120), typicalModes, allCodecs)
        }
    }

    @Test
    fun widthWithoutHeightIsRefused() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(width = 1920), typicalModes, allCodecs)
        }
    }

    @Test
    fun aCameraWithoutModesCannotRecord() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(), emptyList(), allCodecs)
        }
    }

    // endregion

    // region chooseVideoConfig: codec

    @Test
    fun h264IsTheDefaultCodec() {
        assertEquals(EncoderCodec.H264, chooseVideoConfig(VideoRequest(), typicalModes, allCodecs).codec)
    }

    @Test
    fun hevcIsUsedWhenAskedForAndAvailable() {
        val result = chooseVideoConfig(VideoRequest(codec = VideoCodec.HEVC), typicalModes, softwareHevc)
        assertEquals(EncoderCodec.HEVC, result.codec)
    }

    @Test
    fun hevcIsRefusedWhenTheDeviceHasNoEncoder() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(codec = VideoCodec.HEVC), typicalModes, noHevc)
        }
    }

    @Test
    fun autoUsesHevcOnlyWithAHardwareEncoder() {
        assertEquals(EncoderCodec.HEVC, chooseVideoConfig(VideoRequest(codec = VideoCodec.AUTO), typicalModes, allCodecs).codec)
        assertEquals(EncoderCodec.H264, chooseVideoConfig(VideoRequest(codec = VideoCodec.AUTO), typicalModes, softwareHevc).codec)
        assertEquals(EncoderCodec.H264, chooseVideoConfig(VideoRequest(codec = VideoCodec.AUTO), typicalModes, noHevc).codec)
    }

    @Test
    fun aSlowerCodecCannotBeUsedAtAFrameRateItCannotDo() {
        val hevcSlowAt1080p60 = { codec: EncoderCodec, _: VideoDimension -> if (codec == EncoderCodec.HEVC) 30 else 60 }
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(codec = VideoCodec.HEVC), typicalModes, allCodecs, codecMaxFps = hevcSlowAt1080p60)
        }
        // H.264 is unaffected.
        assertEquals(60, chooseVideoConfig(VideoRequest(), typicalModes, allCodecs, codecMaxFps = hevcSlowAt1080p60).frameRate)
    }

    // endregion

    // region bitrate

    @Test
    fun formulaBitrateScalesWithPixelsFrameRateAndCodec() {
        assertEquals(15_552_000, formulaBitrate(d(1920, 1080), 30, EncoderCodec.H264))
        assertEquals(18_662_400, formulaBitrate(d(1920, 1080), 60, EncoderCodec.HEVC))
    }

    @Test
    fun formulaBitrateIsClamped() {
        assertEquals(1_000_000, formulaBitrate(d(160, 120), 24, EncoderCodec.H264))
        assertEquals(100_000_000, formulaBitrate(d(7680, 4320), 60, EncoderCodec.H264))
    }

    @Test
    fun referenceBitrateIsScaledToTheChosenMode() {
        val reference = ReferenceBitrate(12_000_000, d(1920, 1080), 30)
        assertEquals(24_000_000, scaleReferenceBitrate(reference, d(1920, 1080), 60))
        assertEquals(5_333_333.0, scaleReferenceBitrate(reference, d(1280, 720), 30).toDouble(), 1.0)
    }

    @Test
    fun theDevicesRecommendationBeatsTheFormula() {
        val reference = ReferenceBitrate(12_000_000, d(1920, 1080), 30)
        val result = chooseVideoConfig(VideoRequest(frameRate = 30), typicalModes, allCodecs, referenceBitrate = { reference })
        assertEquals(12_000_000, result.bitrate)
    }

    @Test
    fun anExplicitBitrateBeatsEverything() {
        val result = chooseVideoConfig(
            VideoRequest(bitrate = 8_000_000),
            typicalModes,
            allCodecs,
            referenceBitrate = { ReferenceBitrate(12_000_000, d(1920, 1080), 30) },
        )
        assertEquals(8_000_000, result.bitrate)
    }

    @Test
    fun aNonPositiveBitrateIsRefused() {
        assertThrows(UnsupportedConfigurationException::class.java) {
            chooseVideoConfig(VideoRequest(bitrate = 0), typicalModes, allCodecs)
        }
    }

    // endregion
}
