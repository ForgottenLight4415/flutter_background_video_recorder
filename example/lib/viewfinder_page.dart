import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recorder_controller.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'viewfinder_bottom_bar.dart';
import 'viewfinder_stage.dart';
import 'viewfinder_top_bar.dart';

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
            bottomInset + (controller.streamsMode ? 560 : 360),
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
          // The page also follows the raw streams (the status pill and the panel).
          listenable: Listenable.merge([controller, controller.streams]),
          // The picture runs from edge to edge, and the lens and zoom controls (and in Video mode
          // the shutter too) float over its lower part, like a camera app.
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
                        TopBar(controller: controller, onSettings: onSettings),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Stage(controller: controller),
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: Scrim(
                                  child: LensControls(controller: controller),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ControlsRail(controller: controller),
                ],
              );
            }
            // The subscription cards of Streams mode need to be read in full, so there they stay
            // below the picture; everything else floats over it.
            final streams = controller.streamsMode;
            return Column(
              children: [
                TopBar(controller: controller, onSettings: onSettings),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: Stage(controller: controller)),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Scrim(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LensControls(controller: controller),
                              if (!streams) BottomBar(controller: controller),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (streams) BottomBar(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }
}
