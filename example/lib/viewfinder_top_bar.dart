import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';
import 'theme.dart';
import 'viewfinder_widgets.dart';

/// The row at the top: recorder status, the current settings and the settings button.
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.controller, required this.onSettings});

  final RecorderController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final streams = controller.streamsMode;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Viewfinder.gutter,
          vertical: 8,
        ),
        child: Row(
          children: [
            StatusPill(controller: controller),
            Expanded(
              child: Center(
                child: SummaryChip(
                  label: controller.summary,
                  onTap: controller.canEdit && !streams ? onSettings : null,
                ),
              ),
            ),
            // The shutter row is gone in Streams mode, and with it the flip button.
            if (streams) ...[
              OverlayIconButton(
                icon: Icons.flip_camera_android_outlined,
                tooltip: 'Switch camera',
                onPressed:
                    controller.cameraLocked ? null : controller.flipCamera,
              ),
              const SizedBox(width: 8),
            ],
            OverlayIconButton(
              icon: Icons.tune_rounded,
              tooltip: 'Settings',
              onPressed: controller.canEdit && !streams ? onSettings : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Ready", the recording time, "Streaming" or "Error", with a dot that pulses while live.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final streaming = controller.streams.anyOpen;
    final label =
        controller.isRecording
            ? controller.elapsedLabel
            : controller.isStarting
            ? 'Starting…'
            : streaming
            ? 'Streaming'
            : controller.status == RecorderStatus.error
            ? 'Error'
            : 'Ready';
    return Semantics(
      label: 'Recorder status',
      value: controller.isRecording ? 'Recording $label' : label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Viewfinder.overlay,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(recording: controller.isRecording, streaming: streaming),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Viewfinder.onCamera,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The red dot of the status pill. It pulses while recording, unless the user turned animations off.
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.recording, this.streaming = false});

  final bool recording;
  final bool streaming;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate =
        (widget.recording || widget.streaming) &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording != widget.recording ||
        oldWidget.streaming != widget.streaming) {
      didChangeDependencies();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.35).animate(_pulse),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              widget.recording
                  ? Viewfinder.record
                  : widget.streaming
                  ? Viewfinder.live
                  : Viewfinder.onCameraMuted,
        ),
      ),
    );
  }
}

/// The settings that will be recorded, for example `16:9 · 1080p · 60`. Tapping it opens the
/// settings.
class SummaryChip extends StatelessWidget {
  const SummaryChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Recording format: $label',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Viewfinder.overlay,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: Viewfinder.onCamera),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
