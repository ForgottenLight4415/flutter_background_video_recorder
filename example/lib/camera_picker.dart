import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'theme.dart';

/// The short letters on the lens discs, and the full names they stand for.
///
/// A back camera is **UW** (ultra-wide), **W** (wide, the main one), **T** (telephoto) or **M**
/// (macro); a front camera is **F** and an external one **EXT**. When a device has two cameras of
/// one kind they are numbered (`T1`, `T2`).
class LensLabel {
  const LensLabel(this.letters, this.name);

  final String letters;
  final String name;
}

LensLabel lensLabelOf(CameraInfo camera) {
  switch (camera.position) {
    case CameraPosition.front:
      return const LensLabel('F', 'Front camera');
    case CameraPosition.external:
      return const LensLabel('EXT', 'External camera');
    case CameraPosition.rear:
      return switch (camera.lensType) {
        CameraLensType.ultraWide => const LensLabel('UW', 'Ultra-wide camera'),
        CameraLensType.wide => const LensLabel('W', 'Wide camera'),
        CameraLensType.telephoto => const LensLabel('T', 'Telephoto camera'),
        CameraLensType.macro => const LensLabel('M', 'Macro camera'),
        CameraLensType.unknown => const LensLabel('W', 'Camera'),
      };
  }
}

/// A label for every camera, numbered where two share the same letters.
Map<String, LensLabel> lensLabels(List<CameraInfo> cameras) {
  final base = {for (final camera in cameras) camera.id: lensLabelOf(camera)};
  final counts = <String, int>{};
  for (final label in base.values) {
    counts[label.letters] = (counts[label.letters] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return {
    for (final camera in cameras)
      camera.id: () {
        final label = base[camera.id]!;
        if (counts[label.letters]! < 2) return label;
        final number = seen[label.letters] = (seen[label.letters] ?? 0) + 1;
        return LensLabel('${label.letters}$number', '${label.name} $number');
      }(),
  };
}

/// A row of round lens buttons, one per camera on the side the user is looking at. Hidden when
/// there is nothing to choose between.
class CameraPicker extends StatelessWidget {
  const CameraPicker({
    super.key,
    required this.cameras,
    required this.selectedId,
    required this.onSelected,
  });

  final List<CameraInfo> cameras;
  final String? selectedId;

  /// Null while the choice is locked (recording, or a frame session holding the camera).
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    if (cameras.length < 2) return const SizedBox.shrink();
    final labels = lensLabels(cameras);
    final selected = labels[selectedId];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final camera in cameras)
                _LensDisc(
                  label: labels[camera.id]!,
                  selected: camera.id == selectedId,
                  onTap:
                      onSelected == null ? null : () => onSelected!(camera.id),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 18,
          child:
              selected == null
                  ? null
                  : Text(
                    selected.name,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Viewfinder.onCameraMuted,
                    ),
                  ),
        ),
      ],
    );
  }
}

class _LensDisc extends StatelessWidget {
  const _LensDisc({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final LensLabel label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color =
        selected
            ? Viewfinder.onCamera
            : (enabled
                ? Viewfinder.onCameraMuted
                : Viewfinder.onCameraMuted.withValues(alpha: 0.5));
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      // "UW" would be read letter by letter.
      label: label.name,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: label.name,
        child: SizedBox(
          width: Viewfinder.minTarget + 4,
          height: Viewfinder.minTarget,
          child: Center(
            child: Material(
              color: selected ? Viewfinder.selected : Viewfinder.overlay,
              shape: CircleBorder(
                side:
                    selected
                        ? const BorderSide(color: Viewfinder.onCamera, width: 2)
                        : BorderSide.none,
              ),
              child: InkResponse(
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: Center(
                    child: Text(
                      label.letters,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: color,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                      ),
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
