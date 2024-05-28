package services;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.hardware.display.DisplayManager;
import android.media.MediaRecorder;
import android.os.Binder;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;
import android.util.Log;
import android.util.Size;
import android.util.SparseIntArray;
import android.view.Display;
import android.view.Surface;
import android.view.WindowManager;
import android.widget.Toast;

import androidx.annotation.NonNull;

import com.lightsoftware.flutter_background_video_recorder.plugin.FlutterBackgroundVideoRecorderPlugin;

import java.io.File;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class VideoRecorderService extends Service {
    // Class constants
    public static final int SERVICE_ID = 4415;
    public static final String TAG = "LightRecordingService";
    public static final String NOTIFICATION_CHANNEL_ID = "LightRecordingServiceNotification";

    private WindowManager mWindowManager;

    // Handles the camera events
    private CameraDevice mCameraDevice;
    private final CameraDevice.StateCallback mCameraDeviceStateCallback
            = new CameraDevice.StateCallback() {
        @Override
        public void onOpened(@NonNull CameraDevice camera) {
            mCameraDevice = camera;
            startRecord();
            mMediaRecorder.start();
            Log.i(TAG, "Recording started");
            Intent broadcastIntent = new Intent();
            broadcastIntent.setAction(FlutterBackgroundVideoRecorderPlugin.RECORDING_RECEIVER);
            broadcastIntent.addCategory(Intent.CATEGORY_DEFAULT);
            broadcastIntent.putExtra("msg", "Recording started");
            broadcastIntent.putExtra("code", "RECORDING");
            sendBroadcast(broadcastIntent);
            Log.i(TAG, "Broadcast sent!");
        }

        @Override
        public void onDisconnected(@NonNull CameraDevice camera) {
            camera.close();
            mCameraDevice = null;
        }

        @Override
        public void onError(@NonNull CameraDevice camera, int error) {
            camera.close();
            mCameraDevice = null;
        }
    };

    // Camera variables
    private String mCameraId;
    private Size mVideoSize;
    private int mTotalRotation;
    private String mCameraFacing = "Rear Camera";
    private CaptureRequest.Builder mCaptureRequestBuilder;

    // Media recorder variables
    private MediaRecorder mMediaRecorder;

    // Output file/folder variables
    private String mVideoFolderName;
    private File mVideoFolder;
    private String mVideoFileName;

    private boolean isRecording = false;

    private static final SparseIntArray ORIENTATIONS = new SparseIntArray();
    static {
        ORIENTATIONS.append(Surface.ROTATION_0, 0);
        ORIENTATIONS.append(Surface.ROTATION_90, 90);
        ORIENTATIONS.append(Surface.ROTATION_180, 180);
        ORIENTATIONS.append(Surface.ROTATION_270, 270);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            mMediaRecorder = new MediaRecorder(getApplicationContext());
        } else {
            mMediaRecorder = new MediaRecorder();
        }
        mWindowManager = (WindowManager) this.getSystemService(Context.WINDOW_SERVICE);
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "Service being destroyed");
        super.onDestroy();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        mVideoFolderName = intent.getStringExtra("DirectoryName");
        mCameraFacing = intent.getStringExtra("CameraFacing");

        String notificationTitle = intent.getStringExtra("NotificationTitle");
        String notificationText = intent.getStringExtra("NotificationText");
        NotificationChannel notificationChannel = new NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "RecordingServiceNotification",
                NotificationManager.IMPORTANCE_LOW
        );
        Notification notification
                = new Notification.Builder(getApplicationContext(), NOTIFICATION_CHANNEL_ID)
                .setContentTitle(notificationTitle)
                .setContentText(notificationText)
                .setSmallIcon(android.R.drawable.presence_video_online)
                .setOngoing(true)
                .build();
        NotificationManager notificationManager = getSystemService(NotificationManager.class);
        notificationManager.createNotificationChannel(notificationChannel);
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            startForeground(SERVICE_ID, notification);
        } else {
            startForeground(SERVICE_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        }
        setupCameraAndTargetFolder();
        Log.i(TAG, "Recording service started in foreground");
        return super.onStartCommand(intent, flags, startId);
    }

    public void setupCameraAndTargetFolder() {
        createVideoFolder();
        setupCamera();
    }

    public void startVideoRecording() {
        isRecording = true;
        Log.i(TAG, "Recorder initializing");
        Intent broadcastIntent = new Intent();
        broadcastIntent.setAction(FlutterBackgroundVideoRecorderPlugin.RECORDING_RECEIVER);
        broadcastIntent.addCategory(Intent.CATEGORY_DEFAULT);
        broadcastIntent.putExtra("msg", "Initializing recorder");
        broadcastIntent.putExtra("code", "INITIALIZING");
        sendBroadcast(broadcastIntent);
        createVideoFile();
        connectCamera();
    }

    public String stopVideoRecording() {
        mMediaRecorder.stop();
        mMediaRecorder.reset();
        mMediaRecorder = null;
        closeCamera();
        isRecording = false;
        Log.i(TAG, "Recording stopped");
        Intent broadcastIntent = new Intent();
        broadcastIntent.setAction(FlutterBackgroundVideoRecorderPlugin.RECORDING_RECEIVER);
        broadcastIntent.addCategory(Intent.CATEGORY_DEFAULT);
        broadcastIntent.putExtra("msg", "Recording stopped.");
        broadcastIntent.putExtra("code", "STOPPED");
        sendBroadcast(broadcastIntent);
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
        return mVideoFileName;
    }

    private static class CompareSizeByArea implements Comparator<Size> {
        @Override
        public int compare(Size lhs, Size rhs) {
            return Long.signum((long) lhs.getWidth() * lhs.getHeight() /
                    (long) rhs.getWidth() * rhs.getHeight());
        }
    }

    private void setupCamera() {
        CameraManager cameraManager = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        int lensFacing;
        if (mCameraFacing.equals("Front Camera")) {
            lensFacing = CameraCharacteristics.LENS_FACING_FRONT;
        } else {
            lensFacing = CameraCharacteristics.LENS_FACING_BACK;
        }
        try {
            for (String cameraId: cameraManager.getCameraIdList()) {
                CameraCharacteristics cameraCharacteristics = cameraManager.getCameraCharacteristics(cameraId);
                if (cameraCharacteristics.get(CameraCharacteristics.LENS_FACING) != null) {
                    Integer lensFacingCameraCharacteristics = cameraCharacteristics.get(CameraCharacteristics.LENS_FACING);
                    if (lensFacingCameraCharacteristics != null && lensFacingCameraCharacteristics == lensFacing) {
                        StreamConfigurationMap map = cameraCharacteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                        if (map != null) {
                            int deviceOrientation = getDeviceOrientation();
                            mTotalRotation = sensorToDeviceRotation(cameraCharacteristics, deviceOrientation);
                            mVideoSize = chooseOptimalSize(map.getOutputSizes(MediaRecorder.class));
                            mCameraId = cameraId;
                            return;
                        }
                    }
                }
            }
        } catch (CameraAccessException e) {
            Log.e(TAG, "Camera setup failed.  Make sure you have granted camera permissions and try again.");
            destroyServiceOnException();
        }
    }

    private int getDeviceOrientation() {
        int deviceOrientation;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Display display = getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);
            deviceOrientation = display.getRotation();
        } else {
            deviceOrientation = mWindowManager.getDefaultDisplay().getRotation();
        }
        return deviceOrientation;
    }

    private void connectCamera() {
        CameraManager cameraManager = (CameraManager) getSystemService(Context.CAMERA_SERVICE);
        try {
            cameraManager.openCamera(mCameraId, mCameraDeviceStateCallback, null);
        } catch (CameraAccessException | SecurityException e) {
            Log.e(TAG, "Failed to connect to camera.");
            Toast.makeText(
                    getApplicationContext(),
                    "Connection to camera failed. Make sure you have granted camera permissions to the app or the camera is not in use.",
                    Toast.LENGTH_SHORT
            ).show();
            destroyServiceOnException();
        }
    }

    private void startRecord() {
        try {
            setupMediaRecorder();
            Surface recordSurface = mMediaRecorder.getSurface();
            mCaptureRequestBuilder = mCameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            mCaptureRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
            mCaptureRequestBuilder.addTarget(recordSurface);
            mCameraDevice.createCaptureSession(
                    Collections.singletonList(recordSurface),
                    new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(@NonNull CameraCaptureSession cameraCaptureSession) {
                            try {
                                cameraCaptureSession.setRepeatingRequest(
                                        mCaptureRequestBuilder.build(),
                                        null,
                                        null
                                );
                            } catch (CameraAccessException e) {
                                Log.e(TAG, e.toString());
                            }
                        }

                        @Override
                        public void onConfigureFailed(@NonNull CameraCaptureSession cameraCaptureSession) {
                            Toast.makeText(
                                    getApplicationContext(),
                                    "Failed to create capture session",
                                    Toast.LENGTH_SHORT
                            ).show();
                        }
                    },
                    null
            );
        } catch (IOException | CameraAccessException e) {
            Log.e(TAG, e.toString());
        }
    }

    private void closeCamera() {
        if (mCameraDevice != null) {
            mCameraDevice.close();
            mCameraDevice = null;
        }
    }

    private void setupMediaRecorder() throws IOException {
        mMediaRecorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
        mMediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC);
        mMediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
        mMediaRecorder.setOutputFile(mVideoFileName);
        mMediaRecorder.setVideoEncodingBitRate(10000000);
        mMediaRecorder.setVideoFrameRate(30);
        mMediaRecorder.setVideoSize(mVideoSize.getWidth(), mVideoSize.getHeight());
        mMediaRecorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
        mMediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
        mMediaRecorder.setOrientationHint(mTotalRotation);
        mMediaRecorder.prepare();
    }

    private void createVideoFolder() {
        File videoFile = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES);
        mVideoFolder = new File(videoFile, mVideoFolderName);
        if (!mVideoFolder.exists()) {
            if (!mVideoFolder.mkdirs()) {
                Log.e(TAG, "Failed to create target folder.");
                Toast.makeText(
                        getApplicationContext(),
                        "Failed to create target folder. Make sure you have granted file permissions and try again.",
                        Toast.LENGTH_SHORT
                ).show();
            } else {
                Log.i(TAG, "Target folder created successfully at " + mVideoFolder.getAbsolutePath());
            }
        } else {
            Log.i(TAG, "Target folder exists at " + mVideoFolder.getAbsolutePath());
        }
    }

    private void createVideoFile() {
        try {
            String timeStamp = new SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(new Date());
            String fileBaseName = mVideoFolderName.replace(" ", "");
            String prepend = fileBaseName + "_" + timeStamp;
            File videoFile = File.createTempFile(prepend, ".mp4", mVideoFolder);
            mVideoFileName = videoFile.getAbsolutePath();
        } catch (IOException e) {
            Log.e(TAG, "Failed to create target file.");
            Toast.makeText(
                    getApplicationContext(),
                    "Failed to create target file. Make sure you have granted file permissions and try again.",
                    Toast.LENGTH_SHORT
            ).show();
            destroyServiceOnException();
        }
    }

    private static int sensorToDeviceRotation(CameraCharacteristics cameraCharacteristics, int deviceOrientation) {
        if (cameraCharacteristics != null) {
            Integer sensorOrientation = cameraCharacteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
            if (sensorOrientation != null) {
                deviceOrientation = ORIENTATIONS.get(deviceOrientation);
                return (sensorOrientation + deviceOrientation + 360) % 360;
            }
        }
        return 0;
    }

    private static Size chooseOptimalSize(Size[] choices) {
        List<Size> sizes = new ArrayList<>();
        for (Size option: choices) {
            if (option.getHeight() == option.getWidth() * 1080 / 1920
                    && option.getWidth() >= 1920
                    && option.getHeight() >= 1080) {
                sizes.add(option);
            }
        }
        if (!sizes.isEmpty()) {
            return Collections.min(sizes, new CompareSizeByArea());
        } else {
            return choices[0];
        }
    }

    public boolean getRecordingStatus() {
        return isRecording;
    }

    private void destroyServiceOnException() {
        Intent broadcastIntent = new Intent();
        broadcastIntent.setAction(FlutterBackgroundVideoRecorderPlugin.RECORDING_RECEIVER);
        broadcastIntent.addCategory(Intent.CATEGORY_DEFAULT);
        broadcastIntent.putExtra("msg", "An exception occurred in the recording service.");
        broadcastIntent.putExtra("code", "EXCEPTION");
        sendBroadcast(broadcastIntent);
        this.stopForeground(STOP_FOREGROUND_REMOVE);
        this.stopSelf();
    }

    IBinder mBinder = new LocalBinder();

    public class LocalBinder extends Binder {
        public VideoRecorderService getServerInstance() {
            return VideoRecorderService.this;
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return mBinder;
    }
}
