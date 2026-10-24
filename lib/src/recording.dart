/// State of the recorder.
enum RecorderStatus {
  /// The native recorder did not report a state.
  notInitialized,

  /// Permissions are granted and the camera is being opened. Recording is about to start.
  initializing,

  /// A recording is in progress.
  recording,

  /// No recording is in progress.
  stopped,

  /// The recording failed. See [RecorderException] for the reason.
  error,
}

/// Outcome of starting a recording when no error occurred.
enum StartRecordingResult {
  /// The recording service was started. Follow [RecorderStatus] changes to know when frames
  /// are actually being recorded.
  started,

  /// The user denied a required permission. Asking again is allowed.
  permissionDenied,

  /// A required permission is permanently denied: Android will not show the dialog again. Explain
  /// why it is needed and call [FlutterBackgroundVideoRecorder.openAppSettings] so the user can
  /// grant it there.
  permissionPermanentlyDenied,
}

/// Whether a recording has pictures or only sound.
enum RecordedMediaKind {
  /// A video, saved under `Movies`.
  video,

  /// An audio-only recording, saved under `Recordings`.
  audio,
}

/// A recording that was saved successfully.
class RecordedMedia {
  /// A saved recording found at [uri].
  const RecordedMedia({
    required this.uri,
    this.path,
    this.kind = RecordedMediaKind.video,
    this.hasLocation = false,
  });

  /// True if the position where the video was recorded is stored in its metadata.
  final bool hasLocation;

  /// [RecordedMediaKind.video] for videos (saved under `Movies`), [RecordedMediaKind.audio] for
  /// audio-only recordings (saved under `Recordings`).
  final RecordedMediaKind kind;

  /// Location of the recording: a `content://` URI.
  final String uri;

  /// Absolute file path of the recording when it could be determined, otherwise `null`.
  ///
  /// Prefer [uri]. Since Android 10 apps should not rely on raw file paths.
  final String? path;

  @override
  String toString() =>
      'RecordedMedia(${kind.name}, uri: $uri, path: $path, hasLocation: $hasLocation)';
}
