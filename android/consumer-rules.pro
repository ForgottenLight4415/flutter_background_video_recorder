# The native library looks this class up by name and binds its native methods by name and
# signature in JNI_OnLoad (android/src/main/cpp/jni_bridge.cpp), so neither may be renamed or removed.
-keep class com.lightsoftware.flutter_background_video_recorder.plugin.FrameRingJni {
    native <methods>;
}
