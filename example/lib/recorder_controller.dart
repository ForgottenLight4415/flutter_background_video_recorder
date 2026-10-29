import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'streams_controller.dart';

/// What a [UiMessage] tells the user, which decides how the page shows it.
enum UiMessageKind { saved, warning, error, permissionBlocked }

/// Something the page should tell the user: shown as a snack bar, or (for a permission the user
/// has blocked) as a dialog that leads to the system settings.
class UiMessage {
  const UiMessage(this.kind, this.text);

  final UiMessageKind kind;
  final String text;
}

/// What the capture controls do: record a video, record sound, or hand out the raw streams.
enum CaptureMode { video, audio, streams }

/// The zoom ratios offered as discs, when the camera supports them.
const zoomPresetValues = [0.6, 1.0, 2.0, 3.0, 5.0, 50.0, 100.0];

/// All the state of the viewfinder, and what its buttons do. The page only draws it.
class RecorderController extends ChangeNotifier {
  RecorderController(
    this.recorder, {
    this.tickInterval = const Duration(seconds: 1),
  }) {
    streams = StreamsController(recorder, this);
  }

  /// The raw frame and audio streams of the Streams mode.
  late final StreamsController streams;

  final FlutterBackgroundVideoRecorder recorder;

  /// How often the recording time updates. Null turns the clock off (used by tests).
  final Duration? tickInterval;

  RecorderStatus status = RecorderStatus.notInitialized;
  CameraFacing facing = CameraFacing.rearCamera;
  VideoCapabilities? capabilities;

  /// What will be recorded. Always real values, taken from what the camera supports.
  VideoResolution? resolution;
  int? frameRate;
  VideoCodec codec = VideoCodec.h264;

  // Until the user picks a size, each camera shows its own default (1080p60 where it can).
  bool _sizeChosen = false;

  /// False while the camera's capabilities are being read. The preview waits for them so that it
  /// starts once, with the right size, instead of starting and then restarting.
  bool capabilitiesSettled = false;

  CaptureMode mode = CaptureMode.video;
  bool embedLocation = false;

  /// The cameras of the device, and the one chosen. A null [cameraId] means the first camera that
  /// faces the way [facing] says.
  List<CameraInfo> cameras = const [];
  String? cameraId;

  /// The zoom ratio asked for. It is applied whenever a camera is open, and starts the next
  /// recording, preview or frame session.
  double zoom = 1.0;
  double? _pendingZoom;
  bool _zoomInFlight = false;
  Timer? _zoomRamp;

  /// Recordings keep a preview available (needed to show one while recording).
  bool previewEnabled = true;

  /// Whether the preview is on screen now. Hiding it is just not building the widget.
  bool previewVisible = true;

  /// A start or stop request is on its way.
  bool requestInFlight = false;

  /// Time since the recording was seen to start, or null when not recording.
  Duration? elapsed;

  final _messages = StreamController<UiMessage>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  DateTime? _startedAt;
  Timer? _clock;

  Stream<UiMessage> get messages => _messages.stream;

  bool get audioOnly => mode == CaptureMode.audio;
  bool get streamsMode => mode == CaptureMode.streams;

  bool get isRecording => status == RecorderStatus.recording;
  bool get isStarting => status == RecorderStatus.initializing;

  /// The record button should not react while a request is running or the camera is starting.
  bool get isBusy => requestInFlight || isStarting;

  /// Settings can change only while idle.
  bool get canEdit => !isRecording && !isBusy;

  bool get previewShown =>
      mode == CaptureMode.video && previewEnabled && previewVisible;

  /// The camera in use: the chosen one, or the first that faces the way [facing] says.
  CameraInfo? get selectedCamera {
    for (final camera in cameras) {
      if (cameraId != null ? camera.id == cameraId : _isInGroup(camera)) {
        return camera;
      }
    }
    return null;
  }

  bool _isInGroup(CameraInfo camera) =>
      facing == CameraFacing.frontCamera
          ? camera.position == CameraPosition.front
          : camera.position != CameraPosition.front;

  /// The cameras on the side the user is looking at: all the back (and external) ones, or the
  /// front ones.
  List<CameraInfo> get camerasInGroup => [
    for (final camera in cameras)
      if (_isInGroup(camera)) camera,
  ];

  /// The camera picker locks while recording and while a frame session holds the camera.
  bool get cameraLocked => !canEdit || streams.frameOpen;

  /// The zoom ratios the camera in use supports.
  ZoomRange get zoomRange =>
      selectedCamera?.zoomRange ?? capabilities?.zoomRange ?? ZoomRange.none;

  /// The zoom discs to show: the presets this camera supports.
  List<double> get zoomPresets => [
    for (final value in zoomPresetValues)
      if (zoomRange.contains(value)) value,
  ];

  bool get canZoom => !audioOnly && zoomRange.max > zoomRange.min;

  /// The preview widget may be built: wanted, and the camera's settings are known.
  bool get previewReady => previewShown && capabilitiesSettled;

  VideoMode? get selectedMode =>
      resolution == null ? null : capabilities?.modeFor(resolution!);

  Map<String, List<VideoMode>> get ratios =>
      capabilities?.byAspectRatio ?? const {};

  String? get selectedRatio => resolution?.aspectRatioLabel;

  /// For example `16:9 · 1080p · 60`.
  String get summary {
    if (audioOnly) return 'Audio · AAC';
    if (streamsMode) return 'Raw streams';
    final size = resolution;
    if (size == null) return 'Loading…';
    final parts = [
      size.aspectRatioLabel,
      '${size.height}p',
      if (frameRate != null) '$frameRate',
      if (codec == VideoCodec.hevc) 'HEVC',
      if (codec == VideoCodec.auto) 'Auto',
    ];
    return parts.join(' · ');
  }

  String get elapsedLabel {
    final time = elapsed ?? Duration.zero;
    String two(int value) => value.toString().padLeft(2, '0');
    final hours = time.inHours;
    final minutes = two(time.inMinutes.remainder(60));
    final seconds = two(time.inSeconds.remainder(60));
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Future<void> init() async {
    _subscriptions
      ..add(recorder.recorderState.listen(_onStatus))
      ..add(recorder.recorderWarnings.listen(_onWarning))
      ..add(recorder.recorderErrors.listen(_onRecordingError));
    unawaited(loadCameras());
    unawaited(loadCapabilities());
    // The recorder may still be running from before the app was closed.
    _onStatus(await recorder.getRecordingStatus());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _clock?.cancel();
    _zoomRamp?.cancel();
    streams.dispose();
    _messages.close();
    super.dispose();
  }

  // region Settings

  Future<void> loadCameras() async {
    try {
      cameras = await recorder.listCameras();
      notifyListeners();
    } on RecorderException catch (e) {
      say(UiMessageKind.error, describe(e));
    }
  }

  Future<void> loadCapabilities() async {
    try {
      final loaded = await recorder.getVideoCapabilities(
        facing,
        cameraId: cameraId,
      );
      capabilities = loaded;
      final keep =
          _sizeChosen &&
          resolution != null &&
          loaded.modeFor(resolution!) != null;
      if (!keep) {
        resolution =
            loaded.defaultResolution ??
            (loaded.modes.isEmpty ? null : loaded.modes.first.resolution);
        frameRate = loaded.defaultFrameRate;
      }
      _fixFrameRate();
    } on RecorderException catch (e) {
      say(UiMessageKind.error, describe(e));
    }
    capabilitiesSettled = true;
    notifyListeners();
  }

  void selectRatio(String ratio) {
    final modes = ratios[ratio];
    if (modes == null || modes.isEmpty) return;
    // Keep the device's default size if it has this ratio, otherwise the largest.
    final preferred = capabilities?.defaultResolution;
    final mode = modes.firstWhere(
      (mode) => mode.resolution == preferred,
      orElse: () => modes.first,
    );
    setResolution(mode.resolution);
  }

  void setResolution(VideoResolution value) {
    _sizeChosen = true;
    resolution = value;
    _fixFrameRate();
    notifyListeners();
  }

  void setFrameRate(int value) {
    frameRate = value;
    notifyListeners();
  }

  void setCodec(VideoCodec value) {
    codec = value;
    notifyListeners();
  }

  /// Switches what the capture controls do. Leaving Streams mode closes the raw sessions.
  void setMode(CaptureMode value) {
    if (isRecording || isBusy || mode == value) return;
    final leavingStreams = mode == CaptureMode.streams;
    mode = value;
    if (leavingStreams) unawaited(streams.closeAll());
    notifyListeners();
  }

  void setEmbedLocation(bool value) {
    embedLocation = value;
    notifyListeners();
  }

  void setPreviewEnabled(bool value) {
    previewEnabled = value;
    notifyListeners();
  }

  void togglePreviewVisible() {
    previewVisible = !previewVisible;
    notifyListeners();
  }

  /// Keeps the frame rate valid for the chosen size: 60 if offered, else 30, else the fastest.
  void _fixFrameRate() {
    final rates = selectedMode?.frameRates ?? const <int>[];
    if (rates.isEmpty || rates.contains(frameRate)) return;
    frameRate =
        rates.contains(60) ? 60 : (rates.contains(30) ? 30 : rates.last);
  }

  // endregion

  // region Actions

  Future<void> flipCamera() async {
    if (cameraLocked) return;
    facing =
        facing == CameraFacing.rearCamera
            ? CameraFacing.frontCamera
            : CameraFacing.rearCamera;
    cameraId = null;
    _resetZoom();
    capabilitiesSettled = false;
    notifyListeners();
    await loadCapabilities();
  }

  /// Switches to the camera with the id [id]: another lens on the same side, or another side.
  Future<void> selectCamera(String id) async {
    if (cameraLocked || id == selectedCamera?.id) return;
    final camera = cameras.where((camera) => camera.id == id).firstOrNull;
    if (camera == null) return;
    facing =
        camera.position == CameraPosition.front
            ? CameraFacing.frontCamera
            : CameraFacing.rearCamera;
    cameraId = id;
    _resetZoom();
    capabilitiesSettled = false;
    notifyListeners();
    await loadCapabilities();
  }

  void _resetZoom() {
    _zoomRamp?.cancel();
    zoom = 1.0;
    _pendingZoom = null;
  }

  /// Zooms to [ratio], limited to what the camera supports. Works while recording. Updates
  /// reach the camera one at a time, the latest winning, so a drag does not flood it.
  Future<void> setZoom(double ratio) async {
    zoom = zoomRange.clamp(ratio);
    notifyListeners();
    _pendingZoom = zoom;
    if (_zoomInFlight) return;
    _zoomInFlight = true;
    try {
      while (_pendingZoom != null) {
        final wanted = _pendingZoom!;
        _pendingZoom = null;
        try {
          await recorder.setZoom(wanted);
        } on RecorderException catch (e) {
          // No camera is open yet: the zoom is kept and starts the next session.
          if (e.code != RecorderErrorCode.cameraNotActive) {
            say(UiMessageKind.error, describe(e));
          }
        }
      }
    } finally {
      _zoomInFlight = false;
    }
  }

  /// Zooms to a disc's value, in a short glide unless [animate] is off.
  void zoomTo(double target, {bool animate = true}) {
    _zoomRamp?.cancel();
    target = zoomRange.clamp(target);
    if (!animate || target == zoom) {
      unawaited(setZoom(target));
      return;
    }
    // Ease through the zoom's logarithm, because 1x to 2x should feel like 2x to 4x.
    final from = math.log(zoom);
    final to = math.log(target);
    const steps = 10;
    var step = 0;
    _zoomRamp = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      step++;
      final t = step / steps;
      final eased = 1 - math.pow(1 - t, 3);
      unawaited(
        setZoom(step >= steps ? target : math.exp(from + (to - from) * eased)),
      );
      if (step >= steps) timer.cancel();
    });
  }

  Future<void> toggleRecording() async {
    if (isBusy) return;
    requestInFlight = true;
    notifyListeners();
    try {
      if (isRecording) {
        final media = await recorder.stopRecording();
        say(
          UiMessageKind.saved,
          'Saved ${media.path ?? media.uri}'
          '${media.hasLocation ? ' · with location' : ''}',
        );
      } else {
        final result =
            audioOnly
                ? await recorder.startAudioRecording(
                  folderName: 'Example Recorder',
                  notificationTitle: 'Recording audio',
                  notificationText: 'Tap to return to the app',
                )
                : await recorder.startVideoRecording(
                  folderName: 'Example Recorder',
                  cameraFacing: facing,
                  cameraId: cameraId,
                  notificationTitle: 'Recording video',
                  notificationText: 'Tap to return to the app',
                  settings: VideoSettings(
                    resolution: resolution,
                    frameRate: frameRate,
                    codec: codec,
                    embedLocation: embedLocation,
                    preview: previewEnabled,
                    initialZoom: zoom,
                  ),
                );
        switch (result) {
          case StartRecordingResult.started:
            break;
          case StartRecordingResult.permissionDenied:
            say(
              UiMessageKind.error,
              audioOnly
                  ? 'The microphone permission is required.'
                  : 'The camera and microphone permissions are required.',
            );
          case StartRecordingResult.permissionPermanentlyDenied:
            say(UiMessageKind.permissionBlocked, 'Permissions are blocked.');
        }
      }
    } on RecorderException catch (e) {
      say(UiMessageKind.error, describe(e));
    } finally {
      requestInFlight = false;
      notifyListeners();
    }
  }

  Future<void> openSettings() => recorder.openAppSettings();

  // endregion

  // region Events from the recorder

  void _onStatus(RecorderStatus value) {
    status = value;
    if (value == RecorderStatus.recording) {
      if (_startedAt == null) {
        _startedAt = DateTime.now();
        elapsed = Duration.zero;
        final interval = tickInterval;
        if (interval != null) {
          _clock = Timer.periodic(interval, (_) {
            elapsed = DateTime.now().difference(_startedAt!);
            notifyListeners();
          });
        }
      }
    } else {
      _clock?.cancel();
      _clock = null;
      _startedAt = null;
      elapsed = null;
    }
    notifyListeners();
  }

  void _onWarning(RecorderWarning warning) {
    say(UiMessageKind.warning, switch (warning.code) {
      RecorderWarningCode.thermalWarning =>
        'The device is getting hot. The recording may stop to protect it.',
      RecorderWarningCode.previewUnavailable =>
        'This camera cannot show a preview while recording.',
      RecorderWarningCode.audioOverrun =>
        'The audio stream is falling behind, some sound was dropped.',
      RecorderWarningCode.unknown => 'Warning: ${warning.message}',
    });
  }

  void _onRecordingError(RecorderException error) {
    final saved = error.savedMedia;
    say(
      UiMessageKind.error,
      '${describe(error)}'
      '${saved == null ? '' : ' Saved ${saved.path ?? saved.uri}'}',
    );
  }

  // endregion

  /// Tells the user something through the page: a snack bar, or a dialog for a blocked permission.
  void say(UiMessageKind kind, String text) {
    if (!_messages.isClosed) _messages.add(UiMessage(kind, text));
  }

  /// A sentence for the user for each way an operation can fail.
  static String describe(RecorderException e) => switch (e.code) {
    RecorderErrorCode.cameraBusy =>
      'The camera is busy. Stop the recording, preview or stream that uses it first. After a hot restart, stop the app and run it again.',
    RecorderErrorCode.microphoneBusy =>
      'The microphone is busy. Stop the recording or audio stream that uses it first. After a hot restart, stop the app and run it again.',
    RecorderErrorCode.cameraNotActive => 'There is no open camera to zoom.',
    RecorderErrorCode.permissionDenied =>
      'The permission is needed to start the stream.',
    RecorderErrorCode.alreadyRecording => 'A recording is already running.',
    RecorderErrorCode.notRecording => 'Nothing is being recorded.',
    RecorderErrorCode.foregroundServiceNotAllowed =>
      'Android only lets an app start recording while it is on screen.',
    RecorderErrorCode.unsupportedConfiguration =>
      e.message ?? 'The camera cannot record with these settings.',
    RecorderErrorCode.locationPermissionNotDeclared =>
      'Add ACCESS_FINE_LOCATION to the app manifest to store the location.',
    RecorderErrorCode.cameraDisconnected =>
      'The camera was taken by another app. Recording stopped.',
    RecorderErrorCode.cameraNotFound => 'This device has no such camera.',
    RecorderErrorCode.storageFull =>
      'The device ran out of storage. Recording stopped.',
    RecorderErrorCode.thermalShutdown =>
      'The device overheated. Recording stopped.',
    _ => e.message ?? 'Recording failed (${e.code.name}).',
  };
}
