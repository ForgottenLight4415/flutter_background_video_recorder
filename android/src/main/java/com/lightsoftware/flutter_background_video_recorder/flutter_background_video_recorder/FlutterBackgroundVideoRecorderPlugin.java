package com.lightsoftware.flutter_background_video_recorder.flutter_background_video_recorder;

import static android.content.Context.BIND_AUTO_CREATE;

import static androidx.core.app.ActivityCompat.requestPermissions;
import static androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale;

import io.flutter.embedding.engine.plugins.activity.ActivityAware;

import android.Manifest;
import android.app.Activity;
import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

import flutter_bvr_service.VideoRecorderService;

/** FlutterBackgroundVideoRecorderPlugin */
public class FlutterBackgroundVideoRecorderPlugin extends BroadcastReceiver implements FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener, EventChannel.StreamHandler {
  private static final String TAG = "LightBackgroundVideoRecorder/Plugin";
  private static final int REQUEST_CAMERA_AUDIO_PERMISSION_RESULT = 4415;
  private static final int REQUEST_WRITE_PERMISSION_RESULT = 4416;

  public static final String RECORDING_RECEIVER = "RECORDING_RECEIVER";
  private static final int STATUS_RECORDING = 1;
  private static final int STATUS_STOPPED = 2;
  private static final int STATUS_INITIALIZING = 3;
  private static final int STATUS_EXCEPTION = -1;

  /// The MethodChannel and EventChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private MethodChannel channel;
  private EventChannel eventChannel;
  private EventChannel.EventSink mEventSink;
  private VideoRecorderService mVideoRecordingService;

  private Context mContext;
  private Activity mActivity;
  private final Map<String, Boolean> permissions = new HashMap<>();

  private int mRecordingStatus = STATUS_STOPPED;

  private final ServiceConnection mConnection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName className, IBinder service) {
      Log.i(TAG, "Connection to service established.");
      VideoRecorderService.LocalBinder binder = (VideoRecorderService.LocalBinder) service;
      mVideoRecordingService = binder.getServerInstance();
      boolean isRecording = mVideoRecordingService.getRecordingStatus();
      if (!isRecording) {
        mVideoRecordingService.startVideoRecording();
      } else {
        mRecordingStatus = STATUS_RECORDING;
        Toast.makeText(
                mVideoRecordingService.getApplicationContext(),
                "Recording already in progress.",
                Toast.LENGTH_SHORT
        ).show();
      }
    }

    @Override
    public void onServiceDisconnected(ComponentName arg0) {
      Log.i(TAG, "Service disconnected");
    }
  };

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    Log.i(TAG, "Plugin attached to engine");
    mContext = flutterPluginBinding.getApplicationContext();

    channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "flutter_background_video_recorder");
    channel.setMethodCallHandler(this);

    eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(), "flutter_background_video_recorder_event");
    eventChannel.setStreamHandler(this);

    IntentFilter filter = new IntentFilter(RECORDING_RECEIVER);
    filter.addCategory(Intent.CATEGORY_DEFAULT);
    mContext.registerReceiver(this, filter);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "getRecordingStatus":
        result.success(mRecordingStatus);
        break;
      case "startVideoRecording":
        if (mRecordingStatus == STATUS_STOPPED) {
          checkPermissions();
          if (hasRecordingPermissions()) {
            Intent backgroundServiceStartIntent = new Intent(mContext, VideoRecorderService.class);
            mActivity.startForegroundService(backgroundServiceStartIntent);
            mActivity.bindService(backgroundServiceStartIntent, mConnection, BIND_AUTO_CREATE);
          } else {
            Log.i(TAG, "Permissions not satisfied.");
            checkPermissions();
          }
          result.success(true);
        } else {
          result.error(Integer.toString(10), "Recording in progress", "Recording already in progress");
        }
        break;
      case "stopVideoRecording":
        if (mRecordingStatus == STATUS_RECORDING) {
          String mVideoFileName = mVideoRecordingService.stopVideoRecording();
          mActivity.unbindService(mConnection);
          showToast("File saved: " + mVideoFileName);
          result.success(mVideoFileName);
        } else {
          result.error(Integer.toString(11), "Recording stopped", "Recording already stopped");
        }
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    Log.i(TAG, "Plugin detached from engine");
    channel.setMethodCallHandler(null);
    eventChannel.setStreamHandler(null);

    mContext.unregisterReceiver(this);
  }

  private void checkPermissions() {
    Log.i(TAG, "Checking required permissions");
    // Android 28 (P or Pie) and lower versions need WRITE_EXTERNAL_STORAGE and READ_EXTERNAL_STORAGE permission to access file system.
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
      final String writePermission = Manifest.permission.WRITE_EXTERNAL_STORAGE;
      final String readPermission = Manifest.permission.READ_EXTERNAL_STORAGE;
      final int writePermissionStatus = ContextCompat.checkSelfPermission(mContext, writePermission);
      final int readPermissionStatus = ContextCompat.checkSelfPermission(mContext, readPermission);
      if (writePermissionStatus != PackageManager.PERMISSION_GRANTED || readPermissionStatus != PackageManager.PERMISSION_GRANTED) {
        if (shouldShowRequestPermissionRationale(mActivity, writePermission) || shouldShowRequestPermissionRationale(mActivity, readPermission)) {
          showToast("Read/write permission is required to create and store videos.");
        }
        final String[] permissionsToRequest = new String[] { writePermission, readPermission };
        requestPermissions(mActivity, permissionsToRequest, REQUEST_WRITE_PERMISSION_RESULT);
      } else {
        Log.i(TAG, "Permissions granted: WRITE_EXTERNAL_STORAGE, READ_EXTERNAL_STORAGE");
        permissions.put("WRITE", true);
        permissions.put("READ", true);
      }
    }

    // Irrespective of Android version, the app needs permissions to CAMERA and RECORD_AUDIO
    final String cameraPermission = Manifest.permission.CAMERA;
    final String audioPermission = Manifest.permission.RECORD_AUDIO;
    final int cameraPermissionStatus = ContextCompat.checkSelfPermission(mContext, cameraPermission);
    final int audioPermissionStatus = ContextCompat.checkSelfPermission(mContext, audioPermission);
    if (cameraPermissionStatus != PackageManager.PERMISSION_GRANTED || audioPermissionStatus != PackageManager.PERMISSION_GRANTED) {
      if (shouldShowRequestPermissionRationale(mActivity, Manifest.permission.CAMERA)) {
        showToast("Camera permission is required to record videos");
      }
      if (shouldShowRequestPermissionRationale(mActivity, Manifest.permission.RECORD_AUDIO)) {
        showToast("Microphone permission is required to record videos");
      }
      requestPermissions(mActivity, new String[] { cameraPermission, audioPermission }, REQUEST_CAMERA_AUDIO_PERMISSION_RESULT);
    } else {
      permissions.put("CAMERA", true);
      permissions.put("MIC", true);
    }
    Log.i(TAG, "Permission check complete.");
  }

  private boolean hasRecordingPermissions() {
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
      return Boolean.TRUE.equals(permissions.get("WRITE"))
              && Boolean.TRUE.equals(permissions.get("READ"))
              && Boolean.TRUE.equals(permissions.get("MIC"))
              && Boolean.TRUE.equals(permissions.get("CAMERA"));
    } else {
      return Boolean.TRUE.equals(permissions.get("MIC"))
              && Boolean.TRUE.equals(permissions.get("CAMERA"));
    }
  }

  @Override
  public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
    switch (requestCode) {
      case REQUEST_CAMERA_AUDIO_PERMISSION_RESULT:
        if (grantResults[0] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Camera permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("CAMERA", true);
        }
        if (grantResults[1] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Record audio permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("MIC", true);
        }
        break;
      case REQUEST_WRITE_PERMISSION_RESULT:
        if (grantResults[0] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Write permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("WRITE", true);
        }
        if (grantResults[1] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Read permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("READ", true);
        }
    }
    return true;
  }

  private void showToast(@NonNull String content) {
    Toast.makeText(mContext, content, Toast.LENGTH_SHORT).show();
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    Log.i(TAG, "Plugin attached to activity");
    mActivity = binding.getActivity();
    binding.addRequestPermissionsResultListener(this);

    if (isServiceRunning()) {
      Intent backgroundServiceBindIntent = new Intent(mContext, VideoRecorderService.class);
      mActivity.bindService(backgroundServiceBindIntent, mConnection, BIND_AUTO_CREATE);
    }
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    Log.i(TAG, "Plugin detached from activity for config changes");
    mActivity.unbindService(mConnection);
    mActivity = null;
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    Log.i(TAG, "Plugin reattached to activity for config changes");
    mActivity = binding.getActivity();
    binding.addRequestPermissionsResultListener(this);

    if (isServiceRunning()) {
      Intent backgroundServiceBindIntent = new Intent(mContext, VideoRecorderService.class);
      mActivity.bindService(backgroundServiceBindIntent, mConnection, BIND_AUTO_CREATE);
    }
  }

  @Override
  public void onDetachedFromActivity() {
    Log.i(TAG, "Plugin detached from activity");
    mActivity.unbindService(mConnection);
    mActivity = null;
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    mEventSink = events;
  }

  @Override
  public void onCancel(Object arguments) {
    mEventSink = null;
  }

  @Override
  public void onReceive(Context context, Intent intent) {
    String message = intent.getStringExtra("msg");
    String code = intent.getStringExtra("code");
    Toast.makeText(mContext, message, Toast.LENGTH_SHORT).show();
    Log.i(TAG, "Received code " + code + " with message: " + message);
    switch (code) {
      case "RECORDING":
        mRecordingStatus = STATUS_RECORDING;
        mEventSink.success(STATUS_RECORDING);
        break;
      case "STOPPED":
        mRecordingStatus = STATUS_STOPPED;
        mEventSink.success(STATUS_STOPPED);
        break;
      case "INITIALIZING":
        mRecordingStatus = STATUS_INITIALIZING;
        mEventSink.success(STATUS_INITIALIZING);
        break;
      case "EXCEPTION":
        mRecordingStatus = STATUS_EXCEPTION;
        mEventSink.success(STATUS_EXCEPTION);
        Toast.makeText(mContext, "An exception occurred in recording service", Toast.LENGTH_SHORT).show();
        break;
      default:
        Toast.makeText(mContext, "Illegal broadcast received", Toast.LENGTH_SHORT).show();
    }
  }

  @SuppressWarnings("deprecation")
  private boolean isServiceRunning() {
    ActivityManager manager = (ActivityManager) mContext.getSystemService(Context.ACTIVITY_SERVICE);
    for (ActivityManager.RunningServiceInfo service : manager.getRunningServices(Integer.MAX_VALUE)) {
      if (VideoRecorderService.class.getName().equals(service.service.getClassName())) {
        return true;
      }
    }
    return false;
  }
}
