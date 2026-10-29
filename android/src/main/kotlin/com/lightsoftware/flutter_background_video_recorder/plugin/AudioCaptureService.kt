package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the microphone open and publishes its sound to
 * [AudioSessionHolder]'s sink until it is told to stop. It records nothing to a file.
 *
 * The sound is read on a thread of its own. It is read even when nobody listens (so that the
 * microphone buffer never overflows) and then simply dropped. If the app falls behind, chunks are
 * dropped and a warning is reported, rather than letting a backlog grow.
 */
class AudioCaptureService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val holder get() = AudioSessionHolder.holder

    private var thread: HandlerThread? = null
    private var recorder: AudioRecord? = null
    private var active = false

    @Volatile
    private var reading = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_STOP -> closeSession()
            ACTION_START -> {
                val config = AudioSessionConfig.fromIntent(intent)
                // startForegroundService() obliges us to call startForeground() within seconds.
                if (!enterForeground(config)) {
                    holder.failed("foreground_service_failed", "Could not start the microphone foreground service.")
                    stopSelf()
                } else if (!active) {
                    begin(config)
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (active) release(notifyClosed = true)
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** Closes the stream on request of the app or the notification's Stop action. */
    internal fun closeSession() {
        if (active) release(notifyClosed = true) else holder.closed()
        shutdown()
    }

    private fun enterForeground(config: AudioSessionConfig): Boolean {
        val notification = RecorderNotifications.foreground(
            this,
            title = config.notificationTitle,
            text = config.notificationText,
            stopService = AudioCaptureService::class.java,
            stopAction = ACTION_STOP,
        )
        return try {
            ServiceCompat.startForeground(
                this,
                RecorderNotifications.AUDIO_FOREGROUND_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing permission for the microphone foreground service", e)
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) extends IllegalStateException.
            Log.e(TAG, "Foreground service start not allowed", e)
            false
        }
    }

    @SuppressLint("MissingPermission") // Checked right below.
    private fun begin(sessionConfig: AudioSessionConfig) {
        if (holder.closeRequested) return closeSession()
        val audio = sessionConfig.audio
        audio.problem()?.let { return fail("unsupported_configuration", it) }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return fail("permission_denied", "The microphone permission is required.")
        }

        val channelMask = if (audio.channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val encoding = when (audio.encoding) {
            AudioEncoding.PCM16 -> AudioFormat.ENCODING_PCM_16BIT
            AudioEncoding.PCM_FLOAT -> AudioFormat.ENCODING_PCM_FLOAT
        }
        val minBuffer = AudioRecord.getMinBufferSize(audio.sampleRate, channelMask, encoding)
        if (minBuffer <= 0) return fail("unsupported_configuration", "The microphone cannot record with these settings.")

        val record = try {
            AudioRecord.Builder()
                .setAudioSource(
                    when (audio.source) {
                        AudioSourceKind.MIC -> MediaRecorder.AudioSource.MIC
                        AudioSourceKind.VOICE_RECOGNITION -> MediaRecorder.AudioSource.VOICE_RECOGNITION
                        AudioSourceKind.UNPROCESSED -> MediaRecorder.AudioSource.UNPROCESSED
                    },
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(encoding)
                        .setSampleRate(audio.sampleRate)
                        .setChannelMask(channelMask)
                        .build(),
                )
                // Room for a few chunks, so that a late read does not lose sound.
                .setBufferSizeInBytes(maxOf(minBuffer, audio.chunkBytes * BUFFER_CHUNKS))
                .build()
        } catch (e: UnsupportedOperationException) {
            return fail("unsupported_configuration", "The microphone cannot record with these settings.", e)
        } catch (e: IllegalArgumentException) {
            return fail("unsupported_configuration", "The microphone cannot record with these settings.", e)
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return fail("recording_failed", "The microphone could not be opened. Another app may be using it.")
        }

        active = true
        recorder = record
        try {
            record.startRecording()
        } catch (e: IllegalStateException) {
            return fail("recording_failed", "The microphone could not be started.", e)
        }
        val reader = HandlerThread("fbvr-audio").also { it.start() }
        thread = reader
        reading = true
        Handler(reader.looper).post { readLoop(record, audio) }
        holder.opened(AudioSessionInfo(audio.sampleRate, audio.channels, audio.encoding))
        Log.i(TAG, "Audio stream started")
    }

    /** Reads chunks until the stream is closed. Runs on the audio thread. */
    private fun readLoop(record: AudioRecord, audio: RawAudioConfig) {
        val samplesPerChunk = audio.chunkBytes / audio.encoding.bytesPerSample
        val shorts = ShortArray(if (audio.encoding == AudioEncoding.PCM16) samplesPerChunk else 0)
        val floats = FloatArray(if (audio.encoding == AudioEncoding.PCM_FLOAT) samplesPerChunk else 0)
        var lastOverrunWarning = 0L
        while (reading) {
            var filled = 0
            while (reading && filled < samplesPerChunk) {
                val read = when (audio.encoding) {
                    AudioEncoding.PCM16 -> record.read(shorts, filled, samplesPerChunk - filled)
                    AudioEncoding.PCM_FLOAT ->
                        record.read(floats, filled, samplesPerChunk - filled, AudioRecord.READ_BLOCKING)
                }
                if (read < 0) {
                    if (reading) mainHandler.post { if (active) fail("recording_failed", "The microphone stopped delivering sound (error $read).") }
                    return
                }
                filled += read
            }
            if (!reading) return
            // Keep reading when nobody listens, but spend no work on the sound.
            if (!holder.hub.hasSubscribers) continue
            val bytes = when (audio.encoding) {
                AudioEncoding.PCM16 -> AudioChunkConverter.shortsToBytes(shorts, filled)
                AudioEncoding.PCM_FLOAT -> AudioChunkConverter.floatsToBytes(floats, filled)
            }
            val accepted = holder.hub.publish(
                RawAudioData(bytes, audio.sampleRate, audio.channels, audio.encoding, SystemClock.elapsedRealtimeNanos()),
            )
            val now = SystemClock.elapsedRealtime()
            if (!accepted && now - lastOverrunWarning > OVERRUN_WARNING_INTERVAL_MS) {
                lastOverrunWarning = now
                RecorderStateHolder.warn("audio_overrun", "The app is not taking the audio fast enough; some of it was dropped.")
            }
        }
    }

    private fun fail(code: String, message: String, cause: Throwable? = null) {
        Log.e(TAG, "$code: $message", cause)
        release(notifyClosed = false)
        holder.failed(code, message)
        shutdown()
    }

    private fun release(notifyClosed: Boolean) {
        active = false
        reading = false
        val record = recorder
        recorder = null
        try {
            record?.stop()
        } catch (_: IllegalStateException) {
        }
        // Releasing unblocks a read that is waiting on the audio thread.
        record?.release()
        thread?.quitSafely()
        thread = null
        if (notifyClosed) holder.closed()
    }

    private fun shutdown() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    companion object {
        private const val TAG = "BackgroundVideoRecorder"
        private const val BUFFER_CHUNKS = 8
        private const val OVERRUN_WARNING_INTERVAL_MS = 2_000L

        internal const val ACTION_START = "com.lightsoftware.flutter_background_video_recorder.AUDIO_START"
        internal const val ACTION_STOP = "com.lightsoftware.flutter_background_video_recorder.AUDIO_STOP"

        /** The running service, if any. Only touch it from the main thread. */
        @Volatile
        internal var instance: AudioCaptureService? = null
            private set
    }
}
