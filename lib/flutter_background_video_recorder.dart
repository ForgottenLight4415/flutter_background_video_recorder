/// Record video or audio on Android from a foreground service, so recording continues while the
/// app is in the background, closed, or the screen is off.
///
/// The entry point is [FlutterBackgroundVideoRecorder]. [RecorderPreview] shows what the camera
/// sees, and [FlutterBackgroundVideoRecorderPlatform] is what to replace in tests.
library;

export 'src/flutter_background_video_recorder.dart';
export 'src/models.dart';
export 'src/platform_interface.dart'
    show FlutterBackgroundVideoRecorderPlatform;
export 'src/recorder_preview.dart';
