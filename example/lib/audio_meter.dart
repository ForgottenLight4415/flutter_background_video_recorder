import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// A strip of bars showing how loud the audio stream was over the last moments.
class AudioMeter extends StatefulWidget {
  const AudioMeter({super.key, required this.level, this.bars = 36});

  /// The loudness of the newest chunk, from 0 to 1.
  final ValueListenable<double> level;
  final int bars;

  @override
  State<AudioMeter> createState() => _AudioMeterState();
}

class _AudioMeterState extends State<AudioMeter> {
  late List<double> _history = List.filled(widget.bars, 0);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(AudioMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    setState(() {
      _history = [..._history.skip(1), widget.level.value];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Audio level',
      value: '${(_history.last * 100).round()} percent',
      excludeSemantics: true,
      child: SizedBox(
        height: 48,
        child: CustomPaint(
          size: Size.infinite,
          painter: _BarsPainter(_history),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.levels);

  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / levels.length;
    final paint =
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (slot * 0.55).clamp(2.0, 8.0);
    for (var i = 0; i < levels.length; i++) {
      // Older bars fade, the newest are the brightest.
      final age = (i + 1) / levels.length;
      paint.color = Viewfinder.live.withValues(alpha: 0.25 + 0.75 * age);
      final height = 4 + levels[i].clamp(0.0, 1.0) * (size.height - 4);
      final x = slot * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}
