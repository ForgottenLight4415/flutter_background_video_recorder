import 'dart:async';

import 'package:flutter/material.dart';

import 'camera_picker.dart';
import 'recorder_controller.dart';
import 'streams_panel.dart';
import 'theme.dart';
import 'viewfinder_widgets.dart';
import 'zoom_selector.dart';

/// The controls under the picture in portrait: the mode tabs and the capture button, or in Streams
/// mode the subscription cards.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key, required this.controller});

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
            ModeSwitch(
              mode: controller.mode,
              enabled: controller.canEdit,
              onChanged: controller.setMode,
            ),
            const SizedBox(height: 8),
            if (controller.streamsMode)
              StreamsPanel(streams: controller.streams)
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // The slots keep the shutter centred whichever buttons are there.
                  SizedBox(
                    width: 72,
                    child:
                        controller.audioOnly || !controller.previewEnabled
                            ? null
                            : OverlayIconButton(
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
                  ShutterButton(
                    recording: recording,
                    enabled: !controller.isBusy,
                    onPressed: controller.toggleRecording,
                  ),
                  SizedBox(
                    width: 72,
                    child:
                        controller.audioOnly
                            ? null
                            : OverlayIconButton(
                              icon: Icons.flip_camera_android_outlined,
                              tooltip: 'Switch camera',
                              onPressed:
                                  controller.cameraLocked
                                      ? null
                                      : controller.flipCamera,
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

/// A soft darkening behind controls that float over the picture, so they stay readable on any scene.
class Scrim extends StatelessWidget {
  const Scrim({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000), Color(0xE6000000)],
          stops: [0, 0.45, 1],
        ),
      ),
      child: Padding(padding: const EdgeInsets.only(top: 28), child: child),
    );
  }
}

/// The lens discs and, just below them, the zoom discs. The zoom stays usable while recording.
class LensControls extends StatelessWidget {
  const LensControls({super.key, required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.audioOnly) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CameraPicker(
          cameras: controller.camerasInGroup,
          selectedId: controller.selectedCamera?.id,
          onSelected:
              controller.cameraLocked
                  ? null
                  : (id) => unawaited(controller.selectCamera(id)),
        ),
        ZoomSelector(controller: controller),
      ],
    );
  }
}

/// The controls as a vertical rail, for a phone held sideways.
class ControlsRail extends StatelessWidget {
  const ControlsRail({super.key, required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final streams = controller.streamsMode;
    return SafeArea(
      left: false,
      child: SizedBox(
        // The subscription cards need more room than the shutter.
        width: streams ? 280 : 132,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Column(
            children: [
              ModeSwitch(
                mode: controller.mode,
                enabled: controller.canEdit,
                onChanged: controller.setMode,
                axis: Axis.vertical,
              ),
              const SizedBox(height: 16),
              if (streams)
                StreamsPanel(streams: controller.streams, vertical: true)
              else ...[
                ShutterButton(
                  recording: controller.isRecording,
                  enabled: !controller.isBusy,
                  onPressed: controller.toggleRecording,
                ),
                if (!controller.audioOnly) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (controller.previewEnabled)
                        OverlayIconButton(
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
                      OverlayIconButton(
                        icon: Icons.flip_camera_android_outlined,
                        tooltip: 'Switch camera',
                        onPressed:
                            controller.cameraLocked
                                ? null
                                : controller.flipCamera,
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
