package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat

internal data class Coordinates(val latitude: Double, val longitude: Double)

/** True if the pair is a position MediaRecorder accepts. */
internal fun isValidCoordinates(latitude: Double, longitude: Double): Boolean =
    latitude in -90.0..90.0 && longitude in -180.0..180.0

/**
 * Finds where the device is, once. A video file can only hold a single position, and recording
 * starts while the app is visible, so no background location access is needed.
 */
internal object LocationFetcher {
    private const val FRESH_MAX_AGE_MS = 60_000L
    private const val STALE_MAX_AGE_MS = 10 * 60_000L
    private const val TIMEOUT_MS = 3_000L
    private const val TAG = "BackgroundVideoRecorder"


    /**
     * Calls [onResult] exactly once, on the main thread, with null if no position could be found.
     * Location permission is checked first and a revoked one is handled as no position.
     */
    @SuppressLint("MissingPermission")
    fun fetch(context: Context, onResult: (Coordinates?) -> Unit) {
        val granted = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            .any { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
        if (!granted) return onResult(null)

        try {
            val manager = context.getSystemService(LocationManager::class.java)
            val providers = listOf(
                LocationManager.FUSED_PROVIDER,
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
            ).filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
            if (providers.isEmpty()) {
                Log.i(TAG, "No location provider is enabled")
                return onResult(null)
            }

            val lastKnown = providers
                .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
                .maxByOrNull { it.elapsedRealtimeNanos }
            Log.i(TAG, "Providers $providers, last known ${lastKnown?.let { "${it.provider} ${ageMillis(it)} ms old" }}")
            if (lastKnown != null && ageMillis(lastKnown) <= FRESH_MAX_AGE_MS) {
                return onResult(lastKnown.toCoordinates())
            }

            val handler = Handler(Looper.getMainLooper())
            val cancellation = CancellationSignal()
            var finished = false
            fun finish(fix: Location?) {
                if (finished) return
                finished = true
                handler.removeCallbacksAndMessages(null)
                cancellation.cancel()
                // A slightly old position still beats none.
                val usable = fix ?: lastKnown?.takeIf { ageMillis(it) <= STALE_MAX_AGE_MS }
                Log.i(TAG, "Location result: ${if (fix != null) "current fix" else if (usable != null) "stale last known" else "none"}")
                onResult(usable?.toCoordinates())
            }
            handler.postDelayed({ finish(null) }, TIMEOUT_MS)

            // Ask every provider at once: the first real answer wins, and if all of them come back
            // empty there is no point in waiting for the timeout.
            var pending = providers.size
            for (provider in providers) {
                manager.getCurrentLocation(provider, cancellation, ContextCompat.getMainExecutor(context)) { fix ->
                    pending--
                    Log.i(TAG, "$provider current location: ${if (fix != null) "fix" else "null"}")
                    if (fix != null) finish(fix) else if (pending == 0) finish(null)
                }
            }
        } catch (_: SecurityException) {
            onResult(null)
        }
    }

    private fun ageMillis(location: Location): Long =
        (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000

    private fun Location.toCoordinates(): Coordinates? =
        if (isValidCoordinates(latitude, longitude)) Coordinates(latitude, longitude) else null
}
