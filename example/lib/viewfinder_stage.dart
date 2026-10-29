import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'audio_meter.dart';
import 'frame_view.dart';
import 'recorder_controller.dart';
import 'streams_controller.dart';
import 'theme.dart';

/// The camera picture on black, or a note saying why there is none.
class Stage extends StatelessWidget {
  const Stage({super.key, required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.streamsMode) {
      return StreamsStage(streams: controller.streams);
    }
    if (controller.previewShown) {
      if (!controller.previewReady) {
        return const StageNote(
          icon: Icons.videocam_outlined,
          text: 'Starting camera…',
        );
      }
      // As wide as the screen: the preview takes the full width its shape allows. It sits against
      // the bottom edge, so the controls that float over its lower part are always on the picture;
      // any spare height is black, next to the top bar.
      return Align(
        alignment: Alignment.bottomCenter,
        child: RecorderPreview(
          cameraFacing: controller.facing,
          cameraId: controller.cameraId,
          initialZoom: controller.zoom,
          resolution: controller.resolution,
          placeholder: const StageNote(
            icon: Icons.videocam_outlined,
            text: 'Starting camera…',
          ),
        ),
      );
    }
    return StageNote(
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

/// The stage in Streams mode: what the frame stream delivers, painted by the app itself, with the
/// audio level over it. The camera belongs to the frame session here, so there is no texture.
class StreamsStage extends StatelessWidget {
  const StreamsStage({super.key, required this.streams});

  final StreamsController streams;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: streams,
      builder: (context, _) {
        final info = streams.frameOpen ? streams.frameInfo : null;
        final Widget picture;
        if (streams.frames.opening || streams.audio.opening) {
          picture = const StageNote(icon: Icons.stream, text: 'Starting…');
        } else if (streams.frameOpen) {
          picture = ValueListenableBuilder<RawFrame?>(
            valueListenable: streams.frames.latest,
            builder: (context, frame, _) {
              if (frame == null) {
                return const StageNote(
                  icon: Icons.videocam_outlined,
                  text: 'Waiting for the first frame…',
                );
              }
              return Center(
                child: ClipRect(
                  key: const Key('stream-frame'),
                  child: FrameView(frame: streams.frames.latest),
                ),
              );
            },
          );
        } else if (streams.audioOpen) {
          picture = const StageNote(
            icon: Icons.graphic_eq,
            text: 'Receiving audio',
            subtext: 'Subscribe to video frames to see them here',
          );
        } else {
          picture = const StageNote(
            icon: Icons.stream,
            text: 'Subscribe to a stream to see it here',
            subtext: 'Frames and sound arrive in the app as raw data',
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            picture,
            if (info != null)
              Positioned(
                top: 8,
                left: Viewfinder.gutter,
                child: StageBadge(
                  text:
                      'Live from stream · ${info.width}×${info.height} · '
                      '${info.format == RawFrameFormat.yuv420 ? 'YUV, Y plane shown' : info.format.name.toUpperCase()}',
                ),
              ),
            if (streams.audioOpen)
              Positioned(
                left: Viewfinder.gutter + 8,
                right: Viewfinder.gutter + 8,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Viewfinder.overlay,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: AudioMeter(level: streams.audioLevel),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A small pill over the picture, for example "Live from stream · 1280×720 · YUV".
class StageBadge extends StatelessWidget {
  const StageBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Viewfinder.overlay,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.circle, size: 8, color: Viewfinder.live),
            const SizedBox(width: 6),
            Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: Viewfinder.onCamera),
            ),
          ],
        ),
      ),
    );
  }
}

/// An icon and a line of text on black, for when there is no picture to show.
class StageNote extends StatelessWidget {
  const StageNote({
    super.key,
    required this.icon,
    required this.text,
    this.subtext,
  });

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
