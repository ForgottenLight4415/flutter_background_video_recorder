import 'package:flutter/material.dart';

import 'recorder_controller.dart';
import 'theme.dart';

/// Video / Audio / Streams, like the mode tabs of a camera app.
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onChanged,
    this.axis = Axis.horizontal,
  });

  final CaptureMode mode;
  final bool enabled;
  final ValueChanged<CaptureMode> onChanged;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    return Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, entry)
            in const [
              (CaptureMode.video, 'Video'),
              (CaptureMode.audio, 'Audio'),
              (CaptureMode.streams, 'Streams'),
            ].indexed) ...[
          if (index > 0) const SizedBox(width: 8, height: 8),
          ModeChip(
            label: entry.$2,
            selected: mode == entry.$1,
            onTap: enabled ? () => onChanged(entry.$1) : null,
          ),
        ],
      ],
    );
  }
}

/// One tab of the [ModeSwitch].
class ModeChip extends StatelessWidget {
  const ModeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        selected
            ? Viewfinder.onCamera
            : (onTap == null
                ? Viewfinder.onCameraMuted.withValues(alpha: 0.5)
                : Viewfinder.onCameraMuted);
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? Viewfinder.selected : Colors.transparent,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 72,
              minHeight: Viewfinder.minTarget,
            ),
            // widthFactor: 1 sizes the chip to its label even where the width is bounded (the
            // landscape rail); without it the chip would stretch across the whole rail.
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

/// The big round record button: a red disc that becomes a rounded square while recording.
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    super.key,
    required this.recording,
    required this.enabled,
    required this.onPressed,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = recording ? 'Stop recording' : 'Start recording';
    final animate = !MediaQuery.disableAnimationsOf(context);
    final inner = recording ? 30.0 : 62.0;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Tooltip(
        message: label,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Viewfinder.onCamera, width: 4),
                ),
              ),
              AnimatedContainer(
                duration:
                    animate ? const Duration(milliseconds: 200) : Duration.zero,
                curve: Curves.easeOutCubic,
                width: inner,
                height: inner,
                decoration: BoxDecoration(
                  color:
                      enabled
                          ? Viewfinder.record
                          : Viewfinder.record.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(recording ? 8 : 31),
                ),
              ),
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkResponse(
                    onTap: enabled ? onPressed : null,
                    customBorder: const CircleBorder(),
                    radius: 46,
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

/// A round icon button on a translucent backing, for controls that sit on the picture.
class OverlayIconButton extends StatelessWidget {
  const OverlayIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: Viewfinder.iconSize),
      style: IconButton.styleFrom(
        foregroundColor: Viewfinder.onCamera,
        backgroundColor: Viewfinder.overlay,
        disabledForegroundColor: Viewfinder.onCameraMuted.withValues(
          alpha: 0.4,
        ),
        disabledBackgroundColor: Viewfinder.overlay,
        minimumSize: const Size.square(Viewfinder.minTarget),
      ),
    );
  }
}
