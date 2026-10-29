package com.lightsoftware.flutter_background_video_recorder.plugin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class RawSessionConfigTest {
    @Test
    fun frameConfigDefaultsToYuvAtTheCamerasChoice() {
        val config = RawFrameConfig.fromArguments(emptyMap())
        assertEquals(RawFrameFormat.YUV420, config.format)
        assertNull(config.size)
        assertNull(config.maxFps)
        assertEquals(80, config.jpegQuality)
        assertEquals(1f, config.initialZoom, 0f)
    }

    @Test
    fun frameConfigReadsTheArgumentsOfTheCall() {
        val config = RawFrameConfig.fromArguments(
            mapOf(
                "format" to "jpeg",
                "width" to 640,
                "height" to 480,
                "maxFrameRate" to 15,
                "jpegQuality" to 55,
                "initialZoom" to 2.5,
            ),
        )
        assertEquals(RawFrameFormat.JPEG, config.format)
        assertEquals(VideoDimension(640, 480), config.size)
        assertEquals(15, config.maxFps)
        assertEquals(55, config.jpegQuality)
        assertEquals(2.5f, config.initialZoom, 0f)
    }

    @Test
    fun frameConfigLimitsOutOfRangeValues() {
        val config = RawFrameConfig.fromArguments(mapOf("jpegQuality" to 500, "maxFrameRate" to 0, "width" to 0, "height" to 10))
        assertEquals(100, config.jpegQuality)
        assertNull(config.maxFps)
        assertNull(config.size)
        assertEquals(1, RawFrameConfig.fromArguments(mapOf("jpegQuality" to -4)).jpegQuality)
    }

    @Test
    fun unknownFormatFallsBackToYuv() {
        assertEquals(RawFrameFormat.YUV420, RawFrameFormat.fromWire("bmp"))
        assertEquals(RawFrameFormat.RGBA, RawFrameFormat.fromWire("rgba"))
    }

    @Test
    fun audioConfigDefaultsToMono44100Pcm16() {
        val config = RawAudioConfig.fromArguments(emptyMap())
        assertEquals(44_100, config.sampleRate)
        assertEquals(1, config.channels)
        assertEquals(AudioEncoding.PCM16, config.encoding)
        assertEquals(AudioSourceKind.MIC, config.source)
        assertNull(config.problem())
    }

    @Test
    fun audioConfigReadsTheArgumentsOfTheCall() {
        val config = RawAudioConfig.fromArguments(
            mapOf("sampleRate" to 16000, "channels" to 2, "encoding" to "pcmFloat", "source" to "unprocessed", "chunkMs" to 40),
        )
        assertEquals(16_000, config.sampleRate)
        assertEquals(2, config.channels)
        assertEquals(AudioEncoding.PCM_FLOAT, config.encoding)
        assertEquals(AudioSourceKind.UNPROCESSED, config.source)
        assertEquals(40, config.chunkMs)
    }

    @Test
    fun aChunkIsAWholeNumberOfSampleFrames() {
        // 20 ms of 44.1 kHz stereo 16-bit: 882 sample frames of 4 bytes.
        assertEquals(882 * 4, RawAudioConfig(channels = 2).chunkBytes)
        // Float mono: 4 bytes a sample.
        assertEquals(882 * 4, RawAudioConfig(encoding = AudioEncoding.PCM_FLOAT).chunkBytes)
        assertEquals(0, RawAudioConfig(channels = 2).chunkBytes % RawAudioConfig(channels = 2).frameBytes)
    }

    @Test
    fun audioConfigRejectsWhatTheMicrophoneCannotDo() {
        assertNotNull(RawAudioConfig(channels = 3).problem())
        assertNotNull(RawAudioConfig(channels = 0).problem())
        assertNotNull(RawAudioConfig(sampleRate = 100).problem())
        assertNotNull(RawAudioConfig(sampleRate = 192_000).problem())
        assertNotNull(RawAudioConfig(chunkMs = 0).problem())
        assertNotNull(RawAudioConfig(chunkMs = 5_000).problem())
    }

    @Test
    fun shortsBecomeLittleEndianBytes() {
        val bytes = AudioChunkConverter.shortsToBytes(shortArrayOf(1, -2, 0x1234), 3)
        assertArrayEquals(byteArrayOf(1, 0, -2, -1, 0x34, 0x12), bytes)
    }

    @Test
    fun onlyTheFilledPartOfTheBufferIsConverted() {
        assertEquals(4, AudioChunkConverter.shortsToBytes(ShortArray(100), 2).size)
        assertEquals(8, AudioChunkConverter.floatsToBytes(FloatArray(100), 2).size)
    }

    @Test
    fun floatsBecomeLittleEndianBytes() {
        // 1.0f is 0x3F800000.
        assertArrayEquals(byteArrayOf(0, 0, 0x80.toByte(), 0x3F), AudioChunkConverter.floatsToBytes(floatArrayOf(1f), 1))
    }
}
