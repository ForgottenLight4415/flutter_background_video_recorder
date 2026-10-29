package com.lightsoftware.flutter_background_video_recorder.plugin

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * The sink raw data is published to. Any number of subscribers can read it; every one of them gets
 * every item, in order, on the main thread (the thread Flutter's event channels need).
 *
 * Producers run on their own threads. [publish] is cheap and thread safe, and it refuses an item
 * ([publish] returns false) when [maxPending] items are still waiting for the main thread, so a slow
 * consumer makes the producer drop data instead of piling it up.
 *
 * [post] runs a block on the main thread; tests replace it.
 */
internal class SampleHub<T>(
    private val maxPending: Int,
    private val post: (() -> Unit) -> Unit = defaultPost,
    /**
     * Called on the main thread after every subscriber has seen an item, so the producer's reference
     * to whatever the item holds (a native slot) can be dropped. Not called for an item [publish]
     * refused: the caller still owns that one.
     */
    private val onDispatched: ((T) -> Unit)? = null,
) {
    /** A reader of the sink. Everything it is called with arrives on the main thread. */
    interface Subscriber<T> {
        fun onData(item: T)

        /** A failure that ends the session. [onClosed] follows. */
        fun onError(code: String, message: String)

        /** The session is over; no more data comes. */
        fun onClosed()
    }

    private val subscribers = CopyOnWriteArrayList<Subscriber<T>>()
    private val pending = AtomicInteger(0)

    val hasSubscribers: Boolean get() = subscribers.isNotEmpty()

    /** Whether [publish] would take an item right now. Producers use it to skip expensive work. */
    val canAccept: Boolean get() = subscribers.isNotEmpty() && pending.get() < maxPending

    fun addSubscriber(subscriber: Subscriber<T>) {
        subscribers.addIfAbsent(subscriber)
    }

    fun removeSubscriber(subscriber: Subscriber<T>) {
        subscribers.remove(subscriber)
    }

    /** Hands [item] to the subscribers. Returns false (and drops it) if nobody listens or the sink is full. */
    fun publish(item: T): Boolean {
        if (subscribers.isEmpty()) return false
        // Reserve a slot first, so that two producers cannot both take the last one.
        if (pending.incrementAndGet() > maxPending) {
            pending.decrementAndGet()
            return false
        }
        post {
            pending.decrementAndGet()
            try {
                subscribers.forEach { it.onData(item) }
            } finally {
                onDispatched?.invoke(item)
            }
        }
        return true
    }

    fun publishError(code: String, message: String) {
        post { subscribers.forEach { it.onError(code, message) } }
    }

    fun publishClosed() {
        post { subscribers.forEach { it.onClosed() } }
    }

    private companion object {
        val mainHandler by lazy { Handler(Looper.getMainLooper()) }
        val defaultPost: (() -> Unit) -> Unit = { block -> mainHandler.post(block) }
    }
}

/** What a session reports about itself when it opened, or why it could not. */
internal sealed interface OpenResult<out I> {
    /** The session is open; [info] describes it. */
    data class Opened<I>(val info: I) : OpenResult<I>

    /** The session could not be opened, for the reason in [code] and [message]. */
    data class Failed(val code: String, val message: String) : OpenResult<Nothing>
}

/**
 * The state of one raw session (frames or audio), shared between its service and the plugin: the
 * service outlives the Flutter engine, so the state cannot live in the plugin.
 *
 * Main thread only, except [hub] which producers publish to from their own threads.
 *
 * A session goes IDLE, then STARTING (the service was asked to start), then ACTIVE (it delivers),
 * then IDLE again. The service reports the outcome through [opened], [failed] and [closed].
 */
internal class SessionHolder<T, I>(val hub: SampleHub<T>) {
    /** Where a session is in its life. */
    enum class State { IDLE, STARTING, ACTIVE }

    @Volatile
    var state: State = State.IDLE
        private set

    /** True from the request to open until the session is closed. */
    val isOpen: Boolean get() = state != State.IDLE

    /** Set when a close was requested before the service had come up. */
    @Volatile
    var closeRequested = false

    private var onOpen: ((OpenResult<I>) -> Unit)? = null

    /** Marks the session as starting. [onOpen] gets the outcome once, as soon as it is known. */
    fun begin(onOpen: (OpenResult<I>) -> Unit) {
        check(state == State.IDLE) { "A session is already open." }
        state = State.STARTING
        closeRequested = false
        this.onOpen = onOpen
    }

    fun opened(info: I) {
        if (state != State.STARTING) return
        state = State.ACTIVE
        onOpen?.invoke(OpenResult.Opened(info))
        onOpen = null
    }

    /** The session failed. Before it opened the caller of [begin] hears about it; afterwards the subscribers do. */
    fun failed(code: String, message: String) {
        when (state) {
            State.IDLE -> return
            State.STARTING -> {
                state = State.IDLE
                onOpen?.invoke(OpenResult.Failed(code, message))
                onOpen = null
            }
            State.ACTIVE -> {
                state = State.IDLE
                hub.publishError(code, message)
                hub.publishClosed()
            }
        }
    }

    /** The session ended normally. */
    fun closed() {
        when (state) {
            State.IDLE -> return
            State.STARTING -> failed("recording_failed", "The session was closed before it opened.")
            State.ACTIVE -> {
                state = State.IDLE
                hub.publishClosed()
            }
        }
    }
}

/** The state of the frame session. */
internal object FrameSessionHolder {
    val holder = SessionHolder<RawFrameData, FrameSessionInfo>(
        SampleHub(maxPending = 1, onDispatched = { it.lease.release() }),
    )
}

/** The state of the audio stream. About a second of audio can wait for the main thread. */
internal object AudioSessionHolder {
    val holder = SessionHolder<RawAudioData, AudioSessionInfo>(SampleHub(maxPending = 50))
}
