package com.lightsoftware.flutter_background_video_recorder.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** How the samples of an audio chunk are stored. */
internal enum class AudioEncoding(val wire: String, val bytesPerSample: Int) {
    PCM16("pcm16", 2),
    PCM_FLOAT("pcmFloat", 4),
    ;

    companion object {
        fun fromWire(value: String?): AudioEncoding = entries.firstOrNull { it.wire == value } ?: PCM16
    }
}

/** Which microphone processing the app asked for. */
internal enum class AudioSourceKind(val wire: String) {
    MIC("mic"),
    VOICE_RECOGNITION("voiceRecognition"),
    UNPROCESSED("unprocessed"),
    ;

    companion object {
        fun fromWire(value: String?): AudioSourceKind = entries.firstOrNull { it.wire == value } ?: MIC
    }
}

/** A short piece of sound on its way to the app. */
internal class RawAudioData(
    val bytes: ByteArray,
    val sampleRate: Int,
    val channels: Int,
    val encoding: AudioEncoding,
    val timestampNs: Long,
)

/** What the app is told when an audio stream has opened. */
internal data class AudioSessionInfo(val sampleRate: Int, val channels: Int, val encoding: AudioEncoding)

/** How the app wants its audio. */
internal data class RawAudioConfig(
    val sampleRate: Int = 44_100,
    val channels: Int = 1,
    val encoding: AudioEncoding = AudioEncoding.PCM16,
    val source: AudioSourceKind = AudioSourceKind.MIC,
    val chunkMs: Int = 20,
) {
    /** The number of bytes of one chunk, always a whole number of sample frames. */
    val chunkBytes: Int get() = frameBytes * (sampleRate * chunkMs / 1000).coerceAtLeast(1)

    /** The number of bytes of one sample for every channel. */
    val frameBytes: Int get() = channels * encoding.bytesPerSample

    /** Why the configuration cannot be used, or null when it is fine. */
    fun problem(): String? = when {
        channels !in 1..2 -> "Audio can have 1 or 2 channels."
        sampleRate !in MIN_SAMPLE_RATE..MAX_SAMPLE_RATE -> "The sample rate must be between $MIN_SAMPLE_RATE and $MAX_SAMPLE_RATE Hz."
        chunkMs !in MIN_CHUNK_MS..MAX_CHUNK_MS -> "A chunk must last between $MIN_CHUNK_MS and $MAX_CHUNK_MS ms."
        else -> null
    }

    companion object {
        const val MIN_SAMPLE_RATE = 8_000
        const val MAX_SAMPLE_RATE = 48_000
        const val MIN_CHUNK_MS = 5
        const val MAX_CHUNK_MS = 1_000

        /** Reads the arguments of the `openAudioStream` call. */
        fun fromArguments(args: Map<String, Any?>): RawAudioConfig {
            fun number(key: String) = (args[key] as? Number)?.toInt()
            val defaults = RawAudioConfig()
            return RawAudioConfig(
                sampleRate = number("sampleRate") ?: defaults.sampleRate,
                channels = number("channels") ?: defaults.channels,
                encoding = AudioEncoding.fromWire(args["encoding"] as? String),
                source = AudioSourceKind.fromWire(args["source"] as? String),
                chunkMs = number("chunkMs") ?: defaults.chunkMs,
            )
        }
    }
}

/** Turns samples into the little-endian bytes the app receives. */
internal object AudioChunkConverter {
    fun shortsToBytes(samples: ShortArray, count: Int): ByteArray {
        val buffer = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        buffer.asShortBuffer().put(samples, 0, count)
        return buffer.array()
    }

    fun floatsToBytes(samples: FloatArray, count: Int): ByteArray {
        val buffer = ByteBuffer.allocate(count * 4).order(ByteOrder.LITTLE_ENDIAN)
        buffer.asFloatBuffer().put(samples, 0, count)
        return buffer.array()
    }
}
