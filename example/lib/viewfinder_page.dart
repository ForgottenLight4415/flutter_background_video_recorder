import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';
import 'settings_sheet.dart';
import 'theme.dart';

/// A camera-style screen: the picture fills the screen, with the controls laid over it.
class ViewfinderPage extends StatefulWidget {
  const ViewfinderPage({super.key, required this.controller});

  final RecorderController controller;

  @override
  State<ViewfinderPage> createState() => _ViewfinderPageState();
}

class _ViewfinderPageState extends State<ViewfinderPage> {
  StreamSubscription<UiMessage>? _messages;

  RecorderController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _messages = controller.messages.listen(_onMessage);
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  void _onMessage(UiMessage message) {
    if (!mounted) return;
    if (message.kind == UiMessageKind.permissionBlocked) {
      _offerSettings();
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    final isError = message.kind == UiMessageKind.error;
    final icon = switch (message.kind) {
      UiMessageKind.saved => Icons.check_circle_outline,
      UiMessageKind.warning => Icons.thermostat,
      _ => Icons.error_outline,
    };
    // Float above the controls, not over them.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: isError ? scheme.errorContainer : null,
          margin: EdgeInsets.fromLTRB(
            Viewfinder.gutter,
            0,
            Viewfinder.gutter,
            bottomInset + 200,
          ),
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              Icon(
                icon,
                size: Viewfinder.iconSize,
                color: isError ? scheme.onErrorContainer : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message.text,
                  style:
                      isError
                          ? TextStyle(color: scheme.onErrorContainer)
                          : null,
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// Android no longer shows the permission dialog once it was denied twice, so the only way
  /// forward is the app's settings page.
  Future<void> _offerSettings() async {
    final openSettings = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            icon: const Icon(Icons.lock_outline),
            title: const Text('Permissions needed'),
            content: const Text(
              'Recording needs the camera and microphone. They are blocked for this '
              'app, so please allow them in the app settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open settings'),
              ),
            ],
          ),
    );
    if (openSettings ?? false) await controller.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: Viewfinder.background,
        body: ListenableBuilder(
          listenable: controller,
          // Controls have their own bars above and below the picture, like a camera app, so
          // nothing is drawn over the picture's edges.
          builder: (context, _) {
            void onSettings() => showSettingsSheet(context, controller);
            // Held sideways, the controls move to a rail beside the picture, so that the
            // picture keeps the height.
            if (MediaQuery.orientationOf(context) == Orientation.landscape) {
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        _TopBar(controller: controller, onSettings: onSettings),
                        Expanded(child: _Stage(controller: controller)),
                      ],
                    ),
                  ),
                  _ControlsRail(controller: controller),
                ],
              );
            }
            return Column(
              children: [
                _TopBar(controller: controller, onSettings: onSettings),
                Expanded(child: _Stage(controller: controller)),
                _BottomBar(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

// region Picture

/// The camera picture on black, or a note saying why there is none.
class _Stage extends StatelessWidget {
  const _Stage({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.previewShown) {
      if (!controller.previewReady) {
        return const _StageNote(
          icon: Icons.videocam_outlined,
          text: 'Starting camera…',
        );
      }
      return Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: RecorderPreview(
            cameraFacing: controller.facing,
            resolution: controller.resolution,
            placeholder: const _StageNote(
              icon: Icons.videocam_outlined,
              text: 'Starting camera…',
            ),
          ),
        ),
      );
    }
    return _StageNote(
      icon:
          controller.audioOnly
              ? Icons.mic_none_rounded
              : Icons.visibility_off_outlined,
      text: controller.audioOnly ? 'Audio recording' : 'Preview hidden',
      subtext:
          controller.audioOnly
              ? null
              : controller.isRecording
              ? 'Still recording'
              : null,
    );
  }
}

class _StageNote extends StatelessWidget {
  const _StageNote({required this.icon, required this.text, this.subtext});

  final IconData icon;
  final String text;
  final String? subtext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Viewfinder.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Viewfinder.onCameraMuted),
            const SizedBox(height: 12),
            Text(
              text,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Viewfinder.onCamera,
              ),
            ),
            if (subtext != null)
              Text(
                subtext!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Viewfinder.onCameraMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// endregion

// region Top bar

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.onSettings});

  final RecorderController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Viewfinder.gutter,
          vertical: 8,
        ),
        child: Row(
          children: [
            _StatusPill(controller: controller),
            Expanded(
              child: Center(
                child: _SummaryChip(
                  label: controller.summary,
                  onTap: controller.canEdit ? onSettings : null,
                ),
              ),
            ),
            _OverlayIconButton(
              icon: Icons.tune_rounded,
              tooltip: 'Settings',
              onPressed: controller.canEdit ? onSettings : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final label =
        controller.isRecording
            ? controller.elapsedLabel
            : controller.isStarting
            ? 'Starting…'
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
            _StatusDot(recording: controller.isRecording),
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
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.recording});

  final bool recording;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate =
        widget.recording && !MediaQuery.disableAnimationsOf(context);
    if (animate) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording != widget.recording) didChangeDependencies();
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
              widget.recording ? Viewfinder.record : Viewfinder.onCameraMuted,
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.onTap});

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

// endregion

// region Bottom bar

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final recording = controller.isRecording;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Viewfinder.gutter,
          12,
          Viewfinder.gutter,
          16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeSwitch(
              audioOnly: controller.audioOnly,
              enabled: controller.canEdit,
              onChanged: controller.setAudioOnly,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // The slots keep the shutter centred whichever buttons are there.
                SizedBox(
                  width: 72,
                  child:
                      controller.audioOnly || !controller.previewEnabled
                          ? null
                          : _OverlayIconButton(
                            icon:
                                controller.previewVisible
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                            tooltip:
                                controller.previewVisible
                                    ? 'Hide preview'
                                    : 'Show preview',
                            onPressed: controller.togglePreviewVisible,
                          ),
                ),
                _ShutterButton(
                  recording: recording,
                  enabled: !controller.isBusy,
                  onPressed: controller.toggleRecording,
                ),
                SizedBox(
                  width: 72,
                  child:
                      controller.audioOnly
                          ? null
                          : _OverlayIconButton(
                            icon: Icons.flip_camera_android_outlined,
                            tooltip: 'Switch camera',
                            onPressed:
                                controller.canEdit
                                    ? controller.flipCamera
                                    : null,
                          ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The controls as a vertical rail, for a phone held sideways.
class _ControlsRail extends StatelessWidget {
  const _ControlsRail({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      left: false,
      child: SizedBox(
        width: 132,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ModeSwitch(
                audioOnly: controller.audioOnly,
                enabled: controller.canEdit,
                onChanged: controller.setAudioOnly,
                axis: Axis.vertical,
              ),
              _ShutterButton(
                recording: controller.isRecording,
                enabled: !controller.isBusy,
                onPressed: controller.toggleRecording,
              ),
              if (!controller.audioOnly)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (controller.previewEnabled)
                      _OverlayIconButton(
                        icon:
                            controller.previewVisible
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                        tooltip:
                            controller.previewVisible
                                ? 'Hide preview'
                                : 'Show preview',
                        onPressed: controller.togglePreviewVisible,
                      ),
                    _OverlayIconButton(
                      icon: Icons.flip_camera_android_outlined,
                      tooltip: 'Switch camera',
                      onPressed:
                          controller.canEdit ? controller.flipCamera : null,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Video / Audio, like the mode tabs of a camera app.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.audioOnly,
    required this.enabled,
    required this.onChanged,
    this.axis = Axis.horizontal,
  });

  final bool audioOnly;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    return Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModeChip(
          label: 'Video',
          selected: !audioOnly,
          onTap: enabled ? () => onChanged(false) : null,
        ),
        const SizedBox(width: 8, height: 8),
        _ModeChip(
          label: 'Audio',
          selected: audioOnly,
          onTap: enabled ? () => onChanged(true) : null,
        ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
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
class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
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

class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({
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

// endregion
