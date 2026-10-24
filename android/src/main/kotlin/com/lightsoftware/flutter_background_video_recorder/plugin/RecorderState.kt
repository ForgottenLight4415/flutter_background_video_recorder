package com.lightsoftware.flutter_background_video_recorder.plugin

import android.os.Handler
import android.os.Looper

/** Recorder lifecycle states. [wire] is the value sent over the platform channels. */
internal enum class RecorderStatus(val wire: String) {
    STOPPED("stopped"),
    INITIALIZING("initializing"),
    RECORDING("recording"),
    ERROR("error"),
}

internal interface RecorderStateListener {
    /** [video] is set on failures that still managed to save what was recorded. */
    fun onStateChanged(status: RecorderStatus, errorCode: String?, errorMessage: String?, video: RecordedMedia?)

    /** A problem that does not end the recording, such as the device getting hot. */
    fun onWarning(code: String, message: String) {}
}

/**
 * Process-wide recorder state shared between [VideoRecorderService] and the plugin.
 *
 * The service outlives the Activity and even the Flutter engine, so the state cannot live in the
 * plugin. Listeners are always invoked on the main thread, in the order updates were made.
 */
internal object RecorderStateHolder {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var status: RecorderStatus = RecorderStatus.STOPPED
        private set

    private val listeners = java.util.concurrent.CopyOnWriteArrayList<RecorderStateListener>()

    fun addListener(listener: RecorderStateListener) {
        listeners.addIfAbsent(listener)
    }

    fun removeListener(listener: RecorderStateListener) {
        listeners.remove(listener)
    }

    fun update(
        status: RecorderStatus,
        errorCode: String? = null,
        errorMessage: String? = null,
        video: RecordedMedia? = null,
    ) {
        this.status = status
        mainHandler.post { listeners.forEach { it.onStateChanged(status, errorCode, errorMessage, video) } }
    }

    fun warn(code: String, message: String) {
        mainHandler.post { listeners.forEach { it.onWarning(code, message) } }
    }
}

internal enum class MediaKind(val wire: String) {
    VIDEO("video"),
    AUDIO("audio"),
}

/** Result of a finished recording. [path] is best effort and may be null. */
internal data class RecordedMedia(
    val uri: String,
    val path: String?,
    val kind: MediaKind,
    val hasLocation: Boolean = false,
)
