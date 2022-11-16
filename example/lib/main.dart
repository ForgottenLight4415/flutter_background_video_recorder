import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_bvr.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isRecording = false;
  bool _recorderBusy = false;
  StreamSubscription<int?>? _streamSubscription;
  final _flutterBackgroundVideoRecorderPlugin = FlutterBackgroundVideoRecorder();

  @override
  void initState() {
    super.initState();
    getInitialRecordingStatus();
    listenRecordingState();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    super.dispose();
  }

  Future<void> getInitialRecordingStatus() async {
    _isRecording = await _flutterBackgroundVideoRecorderPlugin.getVideoRecordingStatus() == 1;
  }

  void listenRecordingState() {
    _streamSubscription = _flutterBackgroundVideoRecorderPlugin.recorderState.listen((event) {
      switch (event) {
        case 1:
          _isRecording = true;
          _recorderBusy = true;
          setState(() {});
          break;
        case 2:
          _isRecording = false;
          _recorderBusy = false;
          setState(() {});
          break;
        case 3:
          _recorderBusy = true;
          setState(() {});
          break;
        case -1:
          _isRecording = false;
          setState(() {});
          break;
        default:
          return;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Background video recorder'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ElevatedButton(
                onPressed: () async {
                  if (!_isRecording && !_recorderBusy) {
                    await _flutterBackgroundVideoRecorderPlugin.startVideoRecording();
                    setState(() {});
                  } else if (!_isRecording && _recorderBusy) {
                    return;
                  } else {
                    String filePath = await _flutterBackgroundVideoRecorderPlugin.stopVideoRecording() ?? "None";
                    setState(() {});
                    debugPrint(filePath);
                  }
                },
                child: Text(
                  _isRecording ? "Stop Recording" : "Start Recording",
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
