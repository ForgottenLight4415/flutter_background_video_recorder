import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

enum UiMessageKind { saved, warning, error, permissionBlocked }

/// Something the page should tell the user: shown as a snack bar, or (for a permission the user
/// has blocked) as a dialog that leads to the system settings.
class UiMessage {
  const UiMessage(this.kind, this.text);

  final UiMessageKind kind;
  final String text;
}

/// All the state of the viewfinder, and what its buttons do. The page only draws it.
class RecorderController extends ChangeNotifier {
  RecorderController(
    this.recorder, {
    this.tickInterval = const Duration(seconds: 1),
  });

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

  bool audioOnly = false;
  bool embedLocation = false;

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

  bool get isRecording => status == RecorderStatus.recording;
  bool get isStarting => status == RecorderStatus.initializing;

  /// The record button should not react while a request is running or the camera is starting.
  bool get isBusy => requestInFlight || isStarting;

  /// Settings can change only while idle.
  bool get canEdit => !isRecording && !isBusy;

  bool get previewShown => !audioOnly && previewEnabled && previewVisible;

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
    _messages.close();
    super.dispose();
  }

  // region Settings

  Future<void> loadCapabilities() async {
    try {
      final loaded = await recorder.getVideoCapabilities(facing);
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
      _say(UiMessageKind.error, _describe(e));
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

  void setAudioOnly(bool value) {
    if (!canEdit) return;
    audioOnly = value;
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
    if (!canEdit) return;
    facing =
        facing == CameraFacing.rearCamera
            ? CameraFacing.frontCamera
            : CameraFacing.rearCamera;
    capabilitiesSettled = false;
    notifyListeners();
    await loadCapabilities();
  }

  Future<void> toggleRecording() async {
    if (isBusy) return;
    requestInFlight = true;
    notifyListeners();
    try {
      if (isRecording) {
        final media = await recorder.stopRecording();
        _say(
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
                  notificationTitle: 'Recording video',
                  notificationText: 'Tap to return to the app',
                  settings: VideoSettings(
                    resolution: resolution,
                    frameRate: frameRate,
                    codec: codec,
                    embedLocation: embedLocation,
                    preview: previewEnabled,
                  ),
                );
        switch (result) {
          case StartRecordingResult.started:
            break;
          case StartRecordingResult.permissionDenied:
            _say(
              UiMessageKind.error,
              audioOnly
                  ? 'The microphone permission is required.'
                  : 'The camera and microphone permissions are required.',
            );
          case StartRecordingResult.permissionPermanentlyDenied:
            _say(UiMessageKind.permissionBlocked, 'Permissions are blocked.');
        }
      }
    } on RecorderException catch (e) {
      _say(UiMessageKind.error, _describe(e));
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
    _say(UiMessageKind.warning, switch (warning.code) {
      RecorderWarningCode.thermalWarning =>
        'The device is getting hot. The recording may stop to protect it.',
      RecorderWarningCode.previewUnavailable =>
        'This camera cannot show a preview while recording.',
      RecorderWarningCode.unknown => 'Warning: ${warning.message}',
    });
  }

  void _onRecordingError(RecorderException error) {
    final saved = error.savedMedia;
    _say(
      UiMessageKind.error,
      '${_describe(error)}'
      '${saved == null ? '' : ' Saved ${saved.path ?? saved.uri}'}',
    );
  }

  // endregion

  void _say(UiMessageKind kind, String text) {
    if (!_messages.isClosed) _messages.add(UiMessage(kind, text));
  }

  static String _describe(RecorderException e) => switch (e.code) {
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
