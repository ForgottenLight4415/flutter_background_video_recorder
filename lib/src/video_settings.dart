/// Which camera to record with.
enum CameraFacing {
  /// The camera on the back of the device.
  rearCamera,

  /// The camera on the screen side of the device, for selfies.
  frontCamera,
}

/// Where a camera sits on the device.
enum CameraPosition {
  /// On the screen side of the device, for selfies.
  front,

  /// On the back of the device.
  rear,

  /// An external camera, for example one connected over USB.
  external,
}

/// The kind of lens of a camera, as far as it can be told from the camera's measurements.
///
/// See [CameraInfo.lensType] for how it is worked out.
enum CameraLensType {
  /// A wider view than the main camera.
  ultraWide,

  /// The main camera.
  wide,

  /// A narrower view than the main camera, which brings distant things closer.
  telephoto,

  /// A camera made for focusing on very close things.
  macro,

  /// It could not be told, for example because the device does not report the lens size.
  unknown,
}

/// The zoom ratios a camera supports. 1.0 is the camera's normal view, smaller values zoom out
/// and larger values zoom in.
class ZoomRange {
  /// The zoom ratios from [min] to [max].
  const ZoomRange(this.min, this.max);

  /// A camera that cannot zoom.
  static const ZoomRange none = ZoomRange(1, 1);

  /// The smallest ratio, for example 0.6 on a camera that can zoom out.
  final double min;

  /// The largest ratio, for example 10.
  final double max;

  /// Whether [ratio] can be set.
  bool contains(double ratio) => ratio >= min && ratio <= max;

  /// [ratio] limited to this range.
  double clamp(double ratio) => ratio.clamp(min, max);

  @override
  bool operator ==(Object other) =>
      other is ZoomRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => 'ZoomRange($min..$max)';
}

/// One camera of the device, as reported by [FlutterBackgroundVideoRecorder.listCameras].
class CameraInfo {
  /// Describes one camera.
  const CameraInfo({
    required this.id,
    required this.position,
    required this.sensorOrientation,
    this.zoomRange = ZoomRange.none,
    this.focalLengthMm,
    this.focalLengthEquivalentMm,
    this.minimumFocusDistance,
    this.isLogicalMultiCamera = false,
    this.physicalCameraIds = const [],
  });

  /// An opaque id to pass as `cameraId` to pick this camera. It is stable on one device.
  final String id;

  /// Where the camera sits.
  final CameraPosition position;

  /// How many degrees clockwise the sensor is turned relative to the device's natural orientation.
  final int sensorOrientation;

  /// The zoom ratios this camera supports.
  final ZoomRange zoomRange;

  /// The focal length in millimetres, if the device reports it.
  final double? focalLengthMm;

  /// The focal length as it would be on a 35 mm film camera, which makes lenses on sensors of
  /// different sizes comparable (about 24 to 28 for a main camera, 13 to 16 for an ultra-wide
  /// one, 50 and more for a telephoto). Null if the device does not report the sensor size.
  final double? focalLengthEquivalentMm;

  /// The shortest distance the camera can focus at, in diopters (1 divided by the distance in
  /// metres, so a larger number means closer). Null or 0 for a camera that cannot focus.
  final double? minimumFocusDistance;

  /// True for a camera that combines several back cameras and switches between them as the zoom
  /// changes. [zoomRange] then reaches across all of them.
  final bool isLogicalMultiCamera;

  /// The ids of the cameras a [isLogicalMultiCamera] camera is made of. For information only:
  /// they cannot be chosen directly.
  final List<String> physicalCameraIds;

  /// A guess at the kind of lens, from [focalLengthEquivalentMm] and [minimumFocusDistance]:
  /// under about 20 mm is [CameraLensType.ultraWide]; otherwise a camera that can focus closer than
  /// about 4 cm is [CameraLensType.macro]; under about 40 mm is [CameraLensType.wide]; longer is
  /// [CameraLensType.telephoto]. It is [CameraLensType.unknown] without a focal length.
  ///
  /// It is a heuristic and some devices will be classified differently from how their maker calls
  /// the cameras. Use the measurements themselves if you need to be sure.
  CameraLensType get lensType {
    final equivalent = focalLengthEquivalentMm;
    if (equivalent == null) return CameraLensType.unknown;
    if (equivalent < 20) return CameraLensType.ultraWide;
    if ((minimumFocusDistance ?? 0) >= 25) return CameraLensType.macro;
    if (equivalent < 40) return CameraLensType.wide;
    return CameraLensType.telephoto;
  }

  @override
  String toString() => 'CameraInfo($id, ${position.name}, ${lensType.name})';
}

/// How the video is compressed.
enum VideoCodec {
  /// H.264 (AVC). Plays everywhere. The default.
  h264,

  /// H.265 (HEVC). Roughly 40% smaller files at the same quality, but some players, editors and
  /// upload services still handle it poorly. Check [VideoCapabilities.hevc] first.
  hevc,

  /// HEVC when the device has a hardware HEVC encoder (cheap on battery and heat), otherwise H.264.
  auto,
}

/// A video size. Videos are stored landscape (the [width] is the longer side) and are rotated on
/// playback to match how the device was held, so a portrait recording still uses a landscape size.
class VideoResolution {
  /// A video of [width] by [height] pixels, with [width] the longer side.
  const VideoResolution(this.width, this.height);

  /// The longer side in pixels.
  final int width;

  /// The shorter side in pixels.
  final int height;

  /// [width] divided by [height], for example 1.78 for 16:9.
  double get aspectRatio => width / height;

  /// The aspect ratio as people write it, for example `16:9` or `4:3`.
  String get aspectRatioLabel {
    const known = [
      (16 / 9, '16:9'),
      (4 / 3, '4:3'),
      (3 / 2, '3:2'),
      (1.0, '1:1'),
      (2.0, '2:1'),
      (21 / 9, '21:9'),
      (5 / 4, '5:4'),
      (11 / 9, '11:9'),
    ];
    for (final (ratio, label) in known) {
      if ((aspectRatio - ratio).abs() / ratio < 0.02) {
        return label;
      }
    }
    final divisor = _gcd(width, height);
    return '${width ~/ divisor}:${height ~/ divisor}';
  }

  /// The same aspect ratio for a device held upright, for example `9:16` for a `16:9` video.
  ///
  /// Videos are stored landscape and rotated on playback, so a 16:9 video is 9:16 when it is
  /// recorded with the phone held upright.
  String get portraitAspectRatioLabel {
    final parts = aspectRatioLabel.split(':');
    return '${parts[1]}:${parts[0]}';
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  @override
  bool operator ==(Object other) =>
      other is VideoResolution &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// How the video is recorded. Every field is optional; without any, the recorder uses 1080p at
/// 60 fps, falling back to 1080p at 30 fps and then the best size up to 1080p.
///
/// Anything you set must be supported by the camera, see
/// [FlutterBackgroundVideoRecorder.getVideoCapabilities]; otherwise starting throws a
/// [RecorderException] with [RecorderErrorCode.unsupportedConfiguration].
class VideoSettings {
  /// Settings for one recording. Leave a field out to get its default.
  const VideoSettings({
    this.resolution,
    this.frameRate,
    this.codec = VideoCodec.h264,
    this.bitrate,
    this.embedLocation = false,
    this.preview = false,
    this.initialZoom = 1.0,
  });

  /// The video size. Leave null for the default.
  final VideoResolution? resolution;

  /// Frames per second. Leave null for the highest of 60 and 30 that the chosen size supports.
  final int? frameRate;

  /// How the video is compressed. [VideoCodec.h264] unless you ask for something else.
  final VideoCodec codec;

  /// Video bitrate in bits per second. Leave null to let the recorder pick one that suits the
  /// device, size, frame rate and codec.
  final int? bitrate;

  /// Store where the video was recorded in its metadata (the position when recording started).
  ///
  /// Off by default. The plugin does **not** declare any location permission, so an app that uses
  /// this must add `ACCESS_FINE_LOCATION` and/or `ACCESS_COARSE_LOCATION` to its own
  /// `AndroidManifest.xml`; otherwise starting throws
  /// [RecorderErrorCode.locationPermissionNotDeclared]. The permission is asked for together with
  /// the others, and is optional: if the user denies it, or no position can be found within a few
  /// seconds, the video is recorded without one (see [RecordedMedia.hasLocation]).
  final bool embedLocation;

  /// Keep the camera picture available to a [RecorderPreview] during this recording.
  ///
  /// Showing or hiding the preview is then just adding or removing the [RecorderPreview] widget;
  /// the recording is not affected either way. Because Android fixes the camera's outputs when the
  /// recording starts, a preview can only be shown during a recording that was started with this
  /// set to true. It costs a little extra GPU work, and on a device that cannot deliver a second
  /// stream next to the recording the recording simply goes ahead without a preview.
  final bool preview;

  /// The zoom ratio the recording starts with, limited to what the camera supports. Change it
  /// later with [FlutterBackgroundVideoRecorder.setZoom], also while recording.
  final double initialZoom;
}

/// A video size and the frame rates it can be recorded at.
class VideoMode {
  /// A [resolution] that can be recorded at each of [frameRates].
  const VideoMode(this.resolution, this.frameRates);

  /// The video size.
  final VideoResolution resolution;

  /// Supported frame rates, ascending.
  final List<int> frameRates;

  @override
  String toString() => 'VideoMode($resolution @ ${frameRates.join('/')} fps)';
}

/// Whether the device can encode a codec.
class CodecSupport {
  /// Describes the encoders of one codec.
  const CodecSupport({
    required this.supported,
    required this.hardwareAccelerated,
  });

  /// True if the device has an encoder for the codec at all.
  final bool supported;

  /// True if a hardware encoder exists. Hardware encoding is much easier on battery and heat.
  final bool hardwareAccelerated;
}

/// What one camera of this device can record.
class VideoCapabilities {
  /// The capabilities of one camera.
  const VideoCapabilities({
    required this.modes,
    required this.h264,
    required this.hevc,
    this.defaultResolution,
    this.defaultFrameRate,
    this.cameraId,
    this.zoomRange = ZoomRange.none,
  });

  /// The id of the camera these capabilities belong to, see [CameraInfo.id].
  final String? cameraId;

  /// The zoom ratios the camera supports.
  final ZoomRange zoomRange;

  /// Supported sizes, largest first.
  final List<VideoMode> modes;

  /// The size a recording uses when [VideoSettings.resolution] is not set: 1080p if the camera
  /// offers it, otherwise the best size up to 1080p. Null if the camera cannot record video.
  final VideoResolution? defaultResolution;

  /// The frame rate a recording uses when [VideoSettings.frameRate] is not set: 60 fps if
  /// [defaultResolution] supports it, otherwise 30.
  final int? defaultFrameRate;

  /// Whether the device can encode H.264, which every device can.
  final CodecSupport h264;

  /// Whether the device can encode HEVC, and whether it does so in hardware.
  final CodecSupport hevc;

  /// The modes grouped by aspect ratio label (`16:9`, `4:3`, ...), in order of first appearance.
  Map<String, List<VideoMode>> get byAspectRatio {
    final groups = <String, List<VideoMode>>{};
    for (final mode in modes) {
      groups.putIfAbsent(mode.resolution.aspectRatioLabel, () => []).add(mode);
    }
    return groups;
  }

  /// The mode for [resolution], or null if the camera cannot record that size.
  VideoMode? modeFor(VideoResolution resolution) {
    for (final mode in modes) {
      if (mode.resolution == resolution) return mode;
    }
    return null;
  }
}
