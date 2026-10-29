import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'streams_controller.dart';
import 'theme.dart';

/// "1.2 MB/s", "340 KB/s".
String formatRate(double bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).round()} KB/s';
}

String _formatFormat(RawFrameFormat format) => switch (format) {
  RawFrameFormat.yuv420 => 'YUV',
  RawFrameFormat.jpeg => 'JPEG',
  RawFrameFormat.rgba => 'RGBA',
};

/// What replaces the capture button in Streams mode: a card for each raw stream, with a switch to
/// subscribe, live numbers, and a stepper that adds or removes listeners of the same session.
class StreamsPanel extends StatelessWidget {
  const StreamsPanel({super.key, required this.streams, this.vertical = false});

  final StreamsController streams;

  /// Stack the cards, for a narrow rail.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final frameInfo = streams.frameOpen ? streams.frameInfo : null;
    final audioInfo = streams.audioOpen ? streams.audioInfo : null;
    final frames = _StreamCard(
      key: const Key('frames-card'),
      title: 'Video frames',
      icon: Icons.videocam_outlined,
      feed: streams.frames,
      subscribeLabel: 'Subscribe to video frames',
      onSubscribed: (on) => streams.setFrameSubscribed(on),
      onAdd: streams.addFrameListener,
      onRemove: streams.removeFrameListener,
      options: Wrap(
        spacing: 6,
        children: [
          for (final format in RawFrameFormat.values)
            ChoiceChip(
              label: Text(_formatFormat(format)),
              selected: streams.frameFormat == format,
              visualDensity: VisualDensity.compact,
              onSelected:
                  streams.frameOpen
                      ? null
                      : (_) => streams.setFrameFormat(format),
            ),
        ],
      ),
      lines: [
        if (frameInfo != null)
          '${frameInfo.width}×${frameInfo.height} · ${streams.frames.perSecond.round()} fps'
        else
          'Not subscribed',
        if (frameInfo != null)
          '${formatRate(streams.frames.bytesPerSecond)} · ${streams.frames.total} frames'
              '${streams.frames.dropped > 0 ? ' · ${streams.frames.dropped} dropped' : ''}',
      ],
    );
    final audio = _StreamCard(
      key: const Key('audio-card'),
      title: 'Audio',
      icon: Icons.mic_none_rounded,
      feed: streams.audio,
      subscribeLabel: 'Subscribe to audio',
      onSubscribed: (on) => streams.setAudioSubscribed(on),
      onAdd: streams.addAudioListener,
      onRemove: streams.removeAudioListener,
      lines: [
        if (audioInfo != null)
          '${(audioInfo.sampleRate / 1000).toStringAsFixed(audioInfo.sampleRate % 1000 == 0 ? 0 : 1)} kHz · '
              '${audioInfo.channels == 1 ? 'mono' : 'stereo'}'
        else
          'Not subscribed',
        if (audioInfo != null)
          '${streams.audio.perSecond.round()} chunks/s · ${formatRate(streams.audio.bytesPerSecond)}',
      ],
    );
    final cards = [frames, audio];
    return vertical
        ? Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final card in cards) ...[card, const SizedBox(height: 8)],
          ],
        )
        : IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: frames),
              const SizedBox(width: 8),
              Expanded(child: audio),
            ],
          ),
        );
  }
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({
    super.key,
    required this.title,
    required this.icon,
    required this.feed,
    required this.subscribeLabel,
    required this.onSubscribed,
    required this.onAdd,
    required this.onRemove,
    required this.lines,
    this.options,
  });

  final String title;
  final IconData icon;
  final RawFeed<Object> feed;
  final String subscribeLabel;
  final ValueChanged<bool> onSubscribed;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final List<String> lines;
  final Widget? options;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final open = feed.isOpen;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Viewfinder.onCameraMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Viewfinder.overlay,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              open
                  ? Viewfinder.live.withValues(alpha: 0.7)
                  : Colors.transparent,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: Viewfinder.onCamera),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Viewfinder.onCamera,
                    ),
                  ),
                ),
                Semantics(
                  label: subscribeLabel,
                  toggled: open,
                  excludeSemantics: true,
                  onTap: feed.opening ? null : () => onSubscribed(!open),
                  child: Switch(
                    value: open,
                    onChanged: feed.opening ? null : onSubscribed,
                  ),
                ),
              ],
            ),
            if (options != null) ...[options!, const SizedBox(height: 4)],
            for (final line in lines) Text(line, style: muted),
            const SizedBox(height: 4),
            Text('Listeners', style: muted),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StepButton(
                  icon: Icons.remove,
                  tooltip: 'Remove a listener',
                  onPressed: open && !feed.opening ? onRemove : null,
                ),
                SizedBox(
                  width: 32,
                  child: Text(
                    '${feed.listeners.length}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Viewfinder.onCamera,
                    ),
                  ),
                ),
                _StepButton(
                  icon: Icons.add,
                  tooltip: 'Add a listener',
                  onPressed: feed.opening ? null : onAdd,
                ),
              ],
            ),
            if (feed.listeners.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final listener in feed.listeners)
                    Text(
                      '#${listener.id}: ${listener.received}',
                      style: muted?.copyWith(color: Viewfinder.live),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
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
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        foregroundColor: Viewfinder.onCamera,
        disabledForegroundColor: Viewfinder.onCameraMuted.withValues(
          alpha: 0.4,
        ),
        minimumSize: const Size.square(Viewfinder.minTarget - 8),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
