import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';
import 'theme.dart';

/// "0.6x", "2x", "2.4x": the zoom ratio as people say it.
String formatZoom(double value) {
  final rounded = (value * 10).round() / 10;
  final text =
      rounded == rounded.roundToDouble()
          ? rounded.toStringAsFixed(0)
          : rounded.toStringAsFixed(1);
  return '${text}x';
}

/// Round zoom buttons for the values the camera supports (0.6x, 1x, 2x, 3x, 5x, 50x and 100x),
/// which turn into a wheel of tick marks while the user drags across them, for fine control.
///
/// Zoom works while recording: it is the one setting that stays unlocked.
class ZoomSelector extends StatefulWidget {
  const ZoomSelector({super.key, required this.controller});

  final RecorderController controller;

  @override
  State<ZoomSelector> createState() => _ZoomSelectorState();
}

class _ZoomSelectorState extends State<ZoomSelector> {
  /// How far the wheel moves for a change of zoom by a factor of two.
  static const _pixelsPerOctave = 80.0;
  static const _releaseDelay = Duration(milliseconds: 700);
  static const _fade = Duration(milliseconds: 160);

  bool _wheel = false;

  // The wheel is only built while it shows or fades out, so that it is not there for nothing.
  bool _wheelBuilt = false;
  Timer? _release;
  Timer? _hide;
  double _log = 0;

  RecorderController get controller => widget.controller;

  @override
  void dispose() {
    _release?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  bool get _animate => !MediaQuery.disableAnimationsOf(context);

  void _dragStart(DragStartDetails details) {
    _release?.cancel();
    _hide?.cancel();
    _log = math.log(controller.zoom);
    setState(() {
      _wheel = true;
      _wheelBuilt = true;
    });
  }

  void _hideWheel() {
    setState(() => _wheel = false);
    _hide?.cancel();
    if (!_animate) {
      setState(() => _wheelBuilt = false);
      return;
    }
    _hide = Timer(_fade, () {
      if (mounted) setState(() => _wheelBuilt = false);
    });
  }

  void _dragUpdate(DragUpdateDetails details) {
    final range = controller.zoomRange;
    final before = _log;
    // The wheel follows the finger: dragging left turns it towards higher values.
    _log -= details.delta.dx / _pixelsPerOctave * math.ln2;
    _log = _log.clamp(math.log(range.min), math.log(range.max));
    for (final preset in controller.zoomPresets) {
      final at = math.log(preset);
      if ((before - at) * (_log - at) < 0) {
        // A light tick as the wheel passes a disc's value.
        unawaited(HapticFeedback.selectionClick().catchError((_) {}));
      }
    }
    unawaited(controller.setZoom(math.exp(_log)));
  }

  void _dragEnd([Object? _]) {
    _release?.cancel();
    if (!_animate) {
      _hideWheel();
      return;
    }
    _release = Timer(_releaseDelay, () {
      if (mounted) _hideWheel();
    });
  }

  void _step(int direction) {
    final presets = controller.zoomPresets;
    final zoom = controller.zoom;
    final target =
        direction > 0
            ? presets.where((p) => p > zoom * 1.01).firstOrNull
            : presets.where((p) => p < zoom / 1.01).lastOrNull;
    if (target != null) controller.zoomTo(target, animate: _animate);
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.canZoom) return const SizedBox.shrink();
    final presets = controller.zoomPresets;
    final zoom = controller.zoom;
    final fade = _animate ? _fade : Duration.zero;
    // The disc nearest to the zoom, comparing ratios rather than differences.
    double? nearest;
    for (final preset in presets) {
      if (nearest == null ||
          (math.log(preset) - math.log(zoom)).abs() <
              (math.log(nearest) - math.log(zoom)).abs()) {
        nearest = preset;
      }
    }
    return Semantics(
      container: true,
      label: 'Zoom',
      value: formatZoom(zoom),
      increasedValue: 'Zoom in',
      decreasedValue: 'Zoom out',
      onIncrease: () => _step(1),
      onDecrease: () => _step(-1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: _dragEnd,
        onHorizontalDragCancel: _dragEnd,
        child: SizedBox(
          height: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedOpacity(
                key: const Key('zoom-discs'),
                opacity: _wheel ? 0 : 1,
                duration: fade,
                child: IgnorePointer(
                  ignoring: _wheel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final preset in presets)
                        _ZoomDisc(
                          preset: preset,
                          selected: preset == nearest,
                          zoom: zoom,
                          onTap:
                              () =>
                                  controller.zoomTo(preset, animate: _animate),
                        ),
                    ],
                  ),
                ),
              ),
              AnimatedOpacity(
                key: const Key('zoom-wheel'),
                opacity: _wheel ? 1 : 0,
                duration: fade,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child:
                        _wheelBuilt
                            ? _ZoomWheel(
                              logValue: math.log(zoom),
                              range: controller.zoomRange,
                              presets: presets,
                              zoom: zoom,
                            )
                            : const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomDisc extends StatelessWidget {
  const _ZoomDisc({
    required this.preset,
    required this.selected,
    required this.zoom,
    required this.onTap,
  });

  final double preset;
  final bool selected;
  final double zoom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The disc in use shows the live value; it is the preset itself when the zoom is on it.
    final shown = selected ? zoom : preset;
    final label = formatZoom(
      (shown - preset).abs() / preset < 0.02 ? preset : shown,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: 'Zoom ${formatZoom(preset)}',
      excludeSemantics: true,
      onTap: onTap,
      child: SizedBox(
        width: Viewfinder.minTarget - 4,
        height: Viewfinder.minTarget,
        child: Center(
          child: Material(
            color: selected ? Viewfinder.selected : Viewfinder.overlay,
            shape: const CircleBorder(),
            child: InkResponse(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: selected ? 42 : 36,
                height: selected ? 42 : 36,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color:
                          selected
                              ? Viewfinder.zoomActive
                              : Viewfinder.onCamera,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tick marks `| | | | |` that replace the discs while dragging.
class _ZoomWheel extends StatelessWidget {
  const _ZoomWheel({
    required this.logValue,
    required this.range,
    required this.presets,
    required this.zoom,
  });

  final double logValue;
  final ZoomRange range;
  final List<double> presets;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _WheelPainter(
              logValue: logValue,
              range: range,
              presets: presets,
            ),
          ),
        ),
        Positioned(
          top: 0,
          child: Text(
            formatZoom(zoom),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Viewfinder.zoomActive,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({
    required this.logValue,
    required this.range,
    required this.presets,
  });

  final double logValue;
  final ZoomRange range;
  final List<double> presets;

  static const _ticksPerOctave = 10;

  @override
  void paint(Canvas canvas, Size size) {
    const pixelsPerNeper = _ZoomSelectorState._pixelsPerOctave / math.ln2;
    final centre = size.width / 2;
    final baseline = size.height - 6;
    final paint =
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2;

    void tick(double zoom, double height, Color color) {
      if (zoom < range.min * 0.999 || zoom > range.max * 1.001) return;
      final x = centre + (math.log(zoom) - logValue) * pixelsPerNeper;
      if (x < 0 || x > size.width) return;
      // Fade towards the edges, so the wheel seems to curve away.
      final edge = ((x - centre).abs() / centre).clamp(0.0, 1.0);
      paint.color = color.withValues(alpha: color.a * (1 - edge * edge));
      canvas.drawLine(Offset(x, baseline), Offset(x, baseline - height), paint);
    }

    // A tick every tenth of an octave, taller on every octave.
    final first = (math.log(range.min) / math.ln2 * _ticksPerOctave).ceil();
    final last = (math.log(range.max) / math.ln2 * _ticksPerOctave).floor();
    for (var i = first; i <= last; i++) {
      final octave = i % _ticksPerOctave == 0;
      tick(
        math.pow(2, i / _ticksPerOctave).toDouble(),
        octave ? 14 : 8,
        octave ? Viewfinder.onCamera : Viewfinder.onCameraMuted,
      );
    }
    // The values of the discs stand out.
    for (final preset in presets) {
      tick(preset, 20, Viewfinder.onCamera);
    }
    // The mark at the middle shows the value the wheel is on.
    paint
      ..color = Viewfinder.zoomActive
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(centre, baseline + 3),
      Offset(centre, baseline - 26),
      paint,
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.logValue != logValue || old.range != range || old.presets != presets;
}
