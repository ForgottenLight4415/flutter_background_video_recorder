import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';
import 'theme.dart';

Future<void> showSettingsSheet(
  BuildContext context,
  RecorderController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _SettingsSheet(controller: controller),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final capabilities = controller.capabilities;
        final editable = controller.canEdit;
        final ratio = controller.selectedRatio;
        final modes =
            ratio == null
                ? const <VideoMode>[]
                : controller.ratios[ratio] ?? const <VideoMode>[];
        final rates = controller.selectedMode?.frameRates ?? const <int>[];
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            Viewfinder.gutter + 8,
            0,
            Viewfinder.gutter + 8,
            32,
          ),
          children: [
            Text('Recording settings', style: theme.textTheme.titleLarge),
            if (!editable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Settings are locked while recording.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (capabilities != null) ...[
              _Section(
                title: 'Aspect ratio',
                hint: 'The vertical ratio is the same video held upright.',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in controller.ratios.entries)
                      ChoiceChip(
                        label: Text(
                          '${entry.key} · ${entry.value.first.resolution.portraitAspectRatioLabel}',
                        ),
                        selected: entry.key == ratio,
                        onSelected:
                            editable
                                ? (_) => controller.selectRatio(entry.key)
                                : null,
                      ),
                  ],
                ),
              ),
              _Section(
                title: 'Resolution',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in modes)
                      ChoiceChip(
                        label: Text(
                          '${mode.resolution.width} × ${mode.resolution.height}',
                        ),
                        selected: mode.resolution == controller.resolution,
                        onSelected:
                            editable
                                ? (_) =>
                                    controller.setResolution(mode.resolution)
                                : null,
                      ),
                  ],
                ),
              ),
              _Section(
                title: 'Frame rate',
                hint: 'Only rates this size can be recorded at are offered.',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final fps in rates)
                      ChoiceChip(
                        label: Text('$fps fps'),
                        selected: fps == controller.frameRate,
                        onSelected:
                            editable
                                ? (_) => controller.setFrameRate(fps)
                                : null,
                      ),
                  ],
                ),
              ),
              _Section(
                title: 'Codec',
                hint: _codecHint(controller.codec, capabilities),
                child: SegmentedButton<VideoCodec>(
                  showSelectedIcon: false,
                  segments: [
                    const ButtonSegment(
                      value: VideoCodec.h264,
                      label: Text('H.264'),
                    ),
                    ButtonSegment(
                      value: VideoCodec.hevc,
                      label: const Text('HEVC'),
                      enabled: capabilities.hevc.supported,
                    ),
                    const ButtonSegment(
                      value: VideoCodec.auto,
                      label: Text('Auto'),
                    ),
                  ],
                  selected: {controller.codec},
                  onSelectionChanged:
                      editable
                          ? (selection) => controller.setCodec(selection.first)
                          : null,
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Preview while recording'),
              subtitle: const Text(
                'Keeps the picture on screen during a recording. It must be chosen before the recording starts.',
              ),
              value: controller.previewEnabled,
              onChanged: editable ? controller.setPreviewEnabled : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Store location in the video'),
              subtitle: const Text(
                'Needs a location permission in the app manifest.',
              ),
              value: controller.embedLocation,
              onChanged: editable ? controller.setEmbedLocation : null,
            ),
          ],
        );
      },
    );
  }

  static String _codecHint(VideoCodec codec, VideoCapabilities capabilities) {
    final hevc = capabilities.hevc;
    return switch (codec) {
      VideoCodec.h264 => 'Plays everywhere.',
      VideoCodec.hevc =>
        !hevc.supported
            ? 'This device cannot encode HEVC.'
            : hevc.hardwareAccelerated
            ? 'About 40% smaller files. Hardware encoder, easy on the battery.'
            : 'About 40% smaller files, but this device encodes it in software.',
      VideoCodec.auto =>
        hevc.supported && hevc.hardwareAccelerated
            ? 'Uses HEVC, as this device has a hardware encoder.'
            : 'Uses H.264, as this device has no hardware HEVC encoder.',
    };
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.hint});

  final String title;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          child,
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
