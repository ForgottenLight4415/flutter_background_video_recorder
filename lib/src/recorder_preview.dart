import 'dart:async';

import 'package:flutter/widgets.dart';

import 'models.dart';
import 'platform_interface.dart';

/// Shows what the camera sees.
///
/// * Before recording it is a viewfinder, so the user can frame the shot. It asks for the camera
///   permission if that is missing.
/// * During a recording that was started with [VideoSettings.preview] it keeps showing the live
///   picture, also after the app was in the background.
///
/// **Hiding the preview is removing this widget** (for example with an `if`). That is all: the
/// recording carries on untouched, and adding the widget again brings the live picture back. When
/// nothing is being recorded, removing it also lets go of the camera.
///
/// The widget sizes itself to the picture's aspect ratio, so put it where it may take the width it
/// is given (for example in a `Center`, a `Column` or an `AspectRatio`-friendly parent).
class RecorderPreview extends StatefulWidget {
  /// Shows the picture of the camera facing [cameraFacing].
  const RecorderPreview({
    super.key,
    required this.cameraFacing,
    this.cameraId,
    this.resolution,
    this.mirrorFront = true,
    this.initialZoom = 1.0,
    this.placeholder = const ColoredBox(color: Color(0xFF000000)),
  });

  /// Which camera to show, when [cameraId] is not set.
  final CameraFacing cameraFacing;

  /// The id of the camera to show, from `listCameras`. It wins over [cameraFacing].
  final String? cameraId;

  /// The zoom ratio the viewfinder starts with. Change it later with
  /// [FlutterBackgroundVideoRecorder.setZoom].
  final double initialZoom;

  /// The size of the video that will be recorded. The preview uses the same aspect ratio, so it
  /// shows what the video will contain. Leave null for the default video size.
  final VideoResolution? resolution;

  /// Show the front camera mirrored, like a mirror. The recorded video is not mirrored.
  final bool mirrorFront;

  /// Shown while the picture is starting, and when there is no picture (for example during a
  /// recording that was started without [VideoSettings.preview]).
  final Widget placeholder;

  @override
  State<RecorderPreview> createState() => _RecorderPreviewState();
}

class _RecorderPreviewState extends State<RecorderPreview>
    with WidgetsBindingObserver {
  PreviewInfo? _info;
  StreamSubscription<RecorderEvent>? _events;

  // The shape of the last picture, so that the placeholder takes the same room and the layout
  // does not jump when the picture goes away.
  double _aspectRatio = 9 / 16;

  // Incremented by every start and stop, so that a slow start can tell it has been overtaken.
  int _generation = 0;

  FlutterBackgroundVideoRecorderPlatform get _platform =>
      FlutterBackgroundVideoRecorderPlatform.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = _platform.recorderEvents
        .where((event) => event.preview != null)
        .listen(_onPreviewEvent);
    _start();
  }

  @override
  void didUpdateWidget(RecorderPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameraFacing != widget.cameraFacing ||
        oldWidget.cameraId != widget.cameraId ||
        oldWidget.resolution != widget.resolution ||
        oldWidget.mirrorFront != widget.mirrorFront) {
      _stop();
      _start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // In the background Android takes the camera away from the viewfinder anyway, and Flutter
    // takes the texture away; start again from scratch when the app is back.
    if (state == AppLifecycleState.paused) {
      _stop();
    } else if (state == AppLifecycleState.resumed && _info == null) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _stop();
    super.dispose();
  }

  void _onPreviewEvent(RecorderEvent event) {
    final info = event.preview!;
    // Only the preview this widget started.
    if (!mounted || _info == null || _info!.textureId != info.textureId) return;
    setState(() {
      _info = info;
      _aspectRatio = info.aspectRatio;
    });
  }

  Future<void> _start() async {
    final generation = ++_generation;
    try {
      final info = await _platform.startPreview(
        cameraFacing: widget.cameraFacing,
        cameraId: widget.cameraId,
        resolution: widget.resolution,
        mirrorFront: widget.mirrorFront,
        initialZoom: widget.initialZoom,
      );
      if (!mounted || generation != _generation) {
        // Removed or replaced while starting.
        unawaited(_platform.stopPreview(info.textureId));
        return;
      }
      setState(() {
        _info = info;
        _aspectRatio = info.aspectRatio;
      });
    } on RecorderException {
      // No permission or no camera: keep showing the placeholder.
    }
  }

  void _stop() {
    _generation++;
    final info = _info;
    _info = null;
    if (info != null) unawaited(_platform.stopPreview(info.textureId));
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null || !info.active) {
      return AspectRatio(aspectRatio: _aspectRatio, child: widget.placeholder);
    }
    return AspectRatio(
      aspectRatio: info.aspectRatio,
      child: Texture(textureId: info.textureId),
    );
  }
}
