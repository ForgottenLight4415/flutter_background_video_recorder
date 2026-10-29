package com.lightsoftware.flutter_background_video_recorder.plugin

import io.flutter.plugin.common.EventChannel

/**
 * Connects an event channel to a session's sink: while the app listens, everything published to the
 * sink is forwarded to it. A session that ends sends a `closed` event instead of closing the
 * channel, because a closed event channel cannot be listened to again.
 */
internal class SessionStreamHandler<T, I>(
    private val holder: SessionHolder<T, I>,
    private val toMap: (T) -> Map<String, Any?>,
) : EventChannel.StreamHandler {
    private var subscriber: SampleHub.Subscriber<T>? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        val subscriber = object : SampleHub.Subscriber<T> {
            override fun onData(item: T) {
                events.success(toMap(item))
            }

            override fun onError(code: String, message: String) {
                events.error(code, message, null)
            }

            override fun onClosed() {
                events.success(mapOf("type" to "closed"))
            }
        }
        this.subscriber = subscriber
        holder.hub.addSubscriber(subscriber)
    }

    override fun onCancel(arguments: Any?) {
        subscriber?.let { holder.hub.removeSubscriber(it) }
        subscriber = null
    }
}
