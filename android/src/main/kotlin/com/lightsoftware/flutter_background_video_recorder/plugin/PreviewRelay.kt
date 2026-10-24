package com.lightsoftware.flutter_background_video_recorder.plugin

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Sits between the camera and the picture shown in Flutter.
 *
 * The camera writes into [createInputSurface]'s surface, which exists for as long as a camera
 * session needs it. Whether anybody is watching is separate: while a Flutter surface is attached
 * ([attach]) every frame is drawn into it, rotated upright; otherwise frames are simply dropped.
 * That is what lets the preview be hidden, or Flutter's surface be destroyed when the app goes to
 * the background, without the camera session (and a recording that depends on it) ever noticing.
 *
 * All OpenGL work runs on one dedicated thread. Public functions may be called from any thread.
 */
internal object PreviewRelay {
    private const val TAG = "BackgroundVideoRecorder"

    private class Target(val eglSurface: EGLSurface, val width: Int, val height: Int)

    private var handler: Handler? = null

    // Everything below is touched on the GL thread only.
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var textureId = 0
    private var positionHandle = 0
    private var texCoordHandle = 0
    private var mvpHandle = 0
    private var texMatrixHandle = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    private var target: Target? = null
    private var rotationDegrees = 0
    private var mirror = false
    private val mvpMatrix = FloatArray(16)
    private val texMatrix = FloatArray(16)

    @Volatile
    var fedByCamera = false
        private set

    /**
     * The camera's output configuration for the relay's surface. The camera service would mirror a
     * front camera's preview by default; the relay decides about mirroring itself, so that it is
     * the same on every device.
     */
    fun outputConfiguration(surface: Surface): android.hardware.camera2.params.OutputConfiguration =
        android.hardware.camera2.params.OutputConfiguration(surface).apply {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                mirrorMode = android.hardware.camera2.params.OutputConfiguration.MIRROR_MODE_NONE
            }
        }

    /** Told (on the thread that asked) the size of the feed whenever a new input surface is made. */
    @Volatile
    var inputSizeListener: ((VideoDimension) -> Unit)? = null

    /** Creates the surface the camera should write to. Replaces any earlier one. */
    fun createInputSurface(width: Int, height: Int): Surface = runOnGl {
        releaseInputLocked()
        val texture = SurfaceTexture(textureId)
        texture.setDefaultBufferSize(width, height)
        texture.setOnFrameAvailableListener({ drawFrame() }, handler)
        val surface = Surface(texture)
        surfaceTexture = texture
        inputSurface = surface
        fedByCamera = true
        surface
    }.also { inputSizeListener?.invoke(VideoDimension(width, height)) }

    /**
     * The camera no longer writes into the surface (the session ended). With [only], nothing
     * happens unless that is still the current input, so a late release by an earlier owner (the
     * viewfinder) cannot take away the surface of a newer one (a recording).
     */
    fun releaseInputSurface(only: Surface? = null) {
        if (handler == null) return
        runOnGl { if (only == null || inputSurface === only) releaseInputLocked() }
    }

    /**
     * Starts drawing into [surface], which is [width] x [height] pixels. The picture is rotated by
     * [rotationDegrees] (clockwise) and optionally mirrored, so it comes out upright.
     */
    fun attach(surface: Surface, width: Int, height: Int, rotationDegrees: Int, mirror: Boolean) {
        runOnGl {
            detachLocked()
            val window = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (window == null || window == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "Could not create the preview window surface: ${EGL14.eglGetError()}")
            } else {
                target = Target(window, width, height)
            }
            this.rotationDegrees = rotationDegrees
            this.mirror = mirror
        }
    }

    /** Stops drawing. Safe to call when nothing is attached. */
    fun detach() {
        if (handler == null) return
        runOnGl { detachLocked() }
    }

    // region GL thread

    private fun <T> runOnGl(block: () -> T): T {
        val gl = ensureThread()
        var result: Any? = null
        var failure: Throwable? = null
        val done = CountDownLatch(1)
        gl.post {
            try {
                if (display == EGL14.EGL_NO_DISPLAY) initGl()
                result = block()
            } catch (t: Throwable) {
                failure = t
            }
            done.countDown()
        }
        if (!done.await(3, TimeUnit.SECONDS)) throw IllegalStateException("The preview thread did not respond.")
        failure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    @Synchronized
    private fun ensureThread(): Handler {
        handler?.let { return it }
        val created = HandlerThread("fbvr-preview").also { it.start() }
        return Handler(created.looper).also { handler = it }
    }

    private fun initGl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "No suitable EGL config"
        }
        config = configs[0]
        context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        // Frames must be drained even when nothing is shown, so there is always a current context.
        pbuffer = EGL14.eglCreatePbufferSurface(
            display,
            config,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
            0,
        )
        check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) { "eglMakeCurrent failed" }

        program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
        texCoordHandle = GLES20.glGetAttribLocation(program, "aTextureCoord")
        mvpHandle = GLES20.glGetUniformLocation(program, "uMVPMatrix")
        texMatrixHandle = GLES20.glGetUniformLocation(program, "uTexMatrix")

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private fun drawFrame() {
        val texture = surfaceTexture ?: return
        val current = target
        try {
            if (current == null) {
                EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
                texture.updateTexImage() // Drain the frame so the camera is never blocked.
                return
            }
            EGL14.eglMakeCurrent(display, current.eglSurface, current.eglSurface, context)
            texture.updateTexImage()
            texture.getTransformMatrix(texMatrix)

            Matrix.setIdentityM(mvpMatrix, 0)
            if (mirror) Matrix.scaleM(mvpMatrix, 0, -1f, 1f, 1f)
            Matrix.rotateM(mvpMatrix, 0, -rotationDegrees.toFloat(), 0f, 0f, 1f)

            GLES20.glViewport(0, 0, current.width, current.height)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glUniformMatrix4fv(mvpHandle, 1, false, mvpMatrix, 0)
            GLES20.glUniformMatrix4fv(texMatrixHandle, 1, false, texMatrix, 0)
            GLES20.glEnableVertexAttribArray(positionHandle)
            GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 8, QUAD_POSITIONS)
            GLES20.glEnableVertexAttribArray(texCoordHandle)
            GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 8, QUAD_TEX_COORDS)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(positionHandle)
            GLES20.glDisableVertexAttribArray(texCoordHandle)

            EGLExt.eglPresentationTimeANDROID(display, current.eglSurface, texture.timestamp)
            if (!EGL14.eglSwapBuffers(display, current.eglSurface)) {
                // The Flutter surface went away without being detached first; stop drawing to it.
                Log.w(TAG, "Preview swap failed (${EGL14.eglGetError()}), detaching")
                detachLocked()
            }
        } catch (e: RuntimeException) {
            // A frame that cannot be shown must never take the camera session down with it.
            Log.w(TAG, "Preview frame dropped", e)
        }
    }

    private fun detachLocked() {
        target?.let {
            EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
            EGL14.eglDestroySurface(display, it.eglSurface)
        }
        target = null
    }

    private fun releaseInputLocked() {
        surfaceTexture?.setOnFrameAvailableListener(null)
        inputSurface?.release()
        surfaceTexture?.release()
        inputSurface = null
        surfaceTexture = null
        fedByCamera = false
    }

    // endregion

    private fun buildProgram(vertex: String, fragment: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] != 0) { "Shader failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertex))
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragment))
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] != 0) { "Program failed: ${GLES20.glGetProgramInfoLog(program)}" }
        return program
    }

    private fun floatBuffer(vararg values: Float): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(values)
            position(0)
        }

    private val QUAD_POSITIONS = floatBuffer(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val QUAD_TEX_COORDS = floatBuffer(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

    private const val VERTEX_SHADER = """
        uniform mat4 uMVPMatrix;
        uniform mat4 uTexMatrix;
        attribute vec4 aPosition;
        attribute vec4 aTextureCoord;
        varying vec2 vTextureCoord;
        void main() {
            gl_Position = uMVPMatrix * aPosition;
            vTextureCoord = (uTexMatrix * aTextureCoord).xy;
        }
    """
    private const val FRAGMENT_SHADER = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        varying vec2 vTextureCoord;
        uniform samplerExternalOES sTexture;
        void main() {
            gl_FragColor = texture2D(sTexture, vTextureCoord);
        }
    """
}
