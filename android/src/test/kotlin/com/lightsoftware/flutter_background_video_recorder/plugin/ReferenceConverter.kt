package com.lightsoftware.flutter_background_video_recorder.plugin

/** One plane of a picture held in a plain array. */
internal class PlaneData(val bytes: ByteArray, val rowStride: Int, val pixelStride: Int)

/**
 * The pixel conversions in plain Kotlin. The product does them in native code (`yuv_convert.cpp`);
 * these are the reference that its results are compared with.
 */
internal object RawFrameConverter {
    fun yuvToNv21(y: PlaneData, u: PlaneData, v: PlaneData, width: Int, height: Int): ByteArray {
        val chromaWidth = (width + 1) / 2
        val chromaHeight = (height + 1) / 2
        val out = ByteArray(width * height + 2 * chromaWidth * chromaHeight)
        var position = 0
        for (row in 0 until height) {
            val start = row * y.rowStride
            for (column in 0 until width) out[position++] = y.bytes[start + column * y.pixelStride]
        }
        for (row in 0 until chromaHeight) {
            for (column in 0 until chromaWidth) {
                out[position++] = v.bytes[row * v.rowStride + column * v.pixelStride]
                out[position++] = u.bytes[row * u.rowStride + column * u.pixelStride]
            }
        }
        return out
    }

    fun yuvToRgba(y: PlaneData, u: PlaneData, v: PlaneData, width: Int, height: Int): ByteArray {
        val out = ByteArray(width * height * 4)
        var position = 0
        for (row in 0 until height) {
            val yRow = row * y.rowStride
            val uRow = (row shr 1) * u.rowStride
            val vRow = (row shr 1) * v.rowStride
            for (column in 0 until width) {
                val luma = y.bytes[yRow + column * y.pixelStride].toInt() and 0xFF
                val blue = (u.bytes[uRow + (column shr 1) * u.pixelStride].toInt() and 0xFF) - 128
                val red = (v.bytes[vRow + (column shr 1) * v.pixelStride].toInt() and 0xFF) - 128
                out[position++] = clamp(luma + ((359 * red) shr 8)).toByte()
                out[position++] = clamp(luma - ((88 * blue + 183 * red) shr 8)).toByte()
                out[position++] = clamp(luma + ((454 * blue) shr 8)).toByte()
                out[position++] = 0xFF.toByte()
            }
        }
        return out
    }

    private fun clamp(value: Int): Int = if (value < 0) 0 else if (value > 255) 255 else value
}
