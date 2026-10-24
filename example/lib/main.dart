import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';
import 'theme.dart';
import 'viewfinder_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.recorder,
    this.tickInterval = const Duration(seconds: 1),
  });

  /// Lets tests supply a recorder backed by a fake platform.
  final FlutterBackgroundVideoRecorder? recorder;

  /// How often the recording time updates. Null turns the clock off (for tests).
  final Duration? tickInterval;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final RecorderController _controller = RecorderController(
    widget.recorder ?? FlutterBackgroundVideoRecorder(),
    tickInterval: widget.tickInterval,
  )..init();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Background recorder',
      theme: Viewfinder.theme(),
      home: ViewfinderPage(controller: _controller),
    );
  }
}
