package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * The notifications of the recorder: the ongoing one Android requires while recording, and the
 * alert shown when a recording ends unexpectedly (the ongoing one is removed with the service, so
 * the user would otherwise not know, particularly with the app closed).
 */
internal object RecorderNotifications {
    /** Id of the ongoing notification, as given to `startForeground`. */
    const val FOREGROUND_ID = 4415

    /** Ids of the ongoing notifications of a frame session and an audio stream. */
    const val FRAME_FOREGROUND_ID = 4417
    const val AUDIO_FOREGROUND_ID = 4418
    private const val ALERT_ID = 4416
    private const val FOREGROUND_CHANNEL = "flutter_background_video_recorder"
    private const val ALERT_CHANNEL = "flutter_background_video_recorder_alerts"

    /**
     * The ongoing notification, with a Stop button and a tap that opens the app. The Stop button
     * sends [stopAction] to [stopService], which is the recording service unless a raw session asks.
     */
    fun foreground(
        context: Context,
        title: String,
        text: String,
        stopService: Class<*> = VideoRecorderService::class.java,
        stopAction: String = VideoRecorderService.ACTION_STOP,
    ): Notification {
        ensureChannel(
            context,
            FOREGROUND_CHANNEL,
            R.string.fbvr_channel_name,
            R.string.fbvr_channel_description,
            NotificationManager.IMPORTANCE_LOW,
        )
        val stop = PendingIntent.getService(
            context,
            0,
            Intent(context, stopService).setAction(stopAction),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(context, FOREGROUND_CHANNEL)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.fbvr_ic_recording)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, context.getString(R.string.fbvr_action_stop), stop)
            .opensApp(context)
            .build()
    }

    /**
     * Tells the user a recording stopped by itself, for the reason in [errorCode], and whether what
     * was recorded up to then was [saved]. Does nothing if notifications are off.
     */
    @SuppressLint("MissingPermission") // canPost() checks the permission.
    fun postFailureAlert(context: Context, errorCode: String, saved: Boolean) {
        if (!canPost(context)) return
        ensureChannel(
            context,
            ALERT_CHANNEL,
            R.string.fbvr_alert_channel_name,
            R.string.fbvr_alert_channel_description,
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        val reason = context.getString(
            when (errorCode) {
                "camera_disconnected" -> R.string.fbvr_alert_reason_camera_lost
                "camera_error" -> R.string.fbvr_alert_reason_camera_error
                "storage_full" -> R.string.fbvr_alert_reason_storage_full
                "thermal_shutdown" -> R.string.fbvr_alert_reason_thermal
                else -> R.string.fbvr_alert_reason_other
            },
        )
        val outcome = context.getString(if (saved) R.string.fbvr_alert_saved else R.string.fbvr_alert_not_saved)
        val notification = NotificationCompat.Builder(context, ALERT_CHANNEL)
            .setContentTitle(context.getString(R.string.fbvr_alert_title))
            .setContentText("$reason $outcome")
            .setStyle(NotificationCompat.BigTextStyle().bigText("$reason $outcome"))
            .setSmallIcon(R.drawable.fbvr_ic_recording)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .opensApp(context)
            .build()
        NotificationManagerCompat.from(context).notify(ALERT_ID, notification)
    }

    /** Removes an earlier alert, for when a new recording starts. */
    fun cancelFailureAlert(context: Context) {
        NotificationManagerCompat.from(context).cancel(ALERT_ID)
    }

    private fun canPost(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                )

    private fun ensureChannel(context: Context, id: String, name: Int, description: Int, importance: Int) {
        val manager = NotificationManagerCompat.from(context)
        if (manager.getNotificationChannel(id) != null) return
        manager.createNotificationChannel(
            NotificationChannel(id, context.getString(name), importance)
                .apply { this.description = context.getString(description) },
        )
    }

    /** Tapping the notification opens the app, if it has a launcher activity. */
    private fun NotificationCompat.Builder.opensApp(context: Context): NotificationCompat.Builder {
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            setContentIntent(
                PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        return this
    }
}
