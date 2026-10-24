import 'errors.dart';
import 'recording.dart';

/// Where to find the picture of a running preview.
class PreviewInfo {
  /// A preview shown by the Flutter [Texture] with [textureId].
  const PreviewInfo({
    required this.textureId,
    required this.width,
    required this.height,
    required this.active,
  });

  /// The id of the Flutter `Texture` that shows the picture.
  final int textureId;

  /// Width of the picture as shown, which is upright: it already accounts for how the device is
  /// held.
  final int width;

  /// Height of the picture as shown, which is upright.
  final int height;

  /// False while there is no picture: for example during a recording that was started without
  /// [VideoSettings.preview], or when the camera is not available.
  final bool active;

  /// [width] divided by [height].
  double get aspectRatio => width / height;
}

/// An event reported by the native recorder: a state change, a warning or a preview change.
///
/// Exactly one of [error] (with a [status] of [RecorderStatus.error]), [warning] and [preview] is
/// meaningful for the corresponding kind of event; a plain state change has none of them.
class RecorderEvent {
  /// A state change to [status], with the [error] that caused it if it is
  /// [RecorderStatus.error].
  const RecorderEvent(this.status, [this.error])
    : warning = null,
      preview = null;

  /// A warning. [status] is [RecorderStatus.notInitialized] and not meaningful.
  const RecorderEvent.warning(RecorderWarning this.warning)
    : status = RecorderStatus.notInitialized,
      error = null,
      preview = null;

  /// The preview changed size or went live or dark. [status] is not meaningful.
  const RecorderEvent.preview(PreviewInfo this.preview)
    : status = RecorderStatus.notInitialized,
      error = null,
      warning = null;

  /// The state the recorder moved to.
  final RecorderStatus status;

  /// Set when [status] is [RecorderStatus.error].
  final RecorderException? error;

  /// Set when this event is a warning and not a state change.
  final RecorderWarning? warning;

  /// Set when this event is about the preview.
  final PreviewInfo? preview;
}
