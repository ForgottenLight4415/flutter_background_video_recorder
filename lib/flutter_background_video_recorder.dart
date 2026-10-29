/// Record video or audio on Android from a foreground service, so recording continues while the
/// app is in the background, closed, or the screen is off.
///
/// The entry point is [FlutterBackgroundVideoRecorder]. It records video and audio, lists the
/// cameras and zooms, and opens raw sessions that hand the camera frames ([RawFrameSession]) or the
/// microphone samples ([RawAudioSession]) to the app itself. [RecorderPreview] shows what the camera
/// sees, and [FlutterBackgroundVideoRecorderPlatform] is what to replace in tests.
library;

export 'src/flutter_background_video_recorder.dart';
export 'src/models.dart';
export 'src/platform_interface.dart'
    show FlutterBackgroundVideoRecorderPlatform;
export 'src/recorder_preview.dart';
