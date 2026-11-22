package com.fyp.smart_traffic;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.view.WindowManager;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * Hardware mode helpers (channel "com.fyp.smart_traffic/hardware"):
 * - bindToWifi / releaseWifi / isBoundToWifi: the ESP32's Wi-Fi network (STMS-RSU) has no
 *   internet, so Android may send the app's traffic over mobile data instead. While Hardware
 *   mode is open, the app process is bound to the Wi-Fi network (ConnectivityManager
 *   .bindProcessToNetwork), so the WebSocket to 192.168.4.1 goes over Wi-Fi. Released when
 *   the user leaves Hardware mode.
 * - keepScreenOn: FLAG_KEEP_SCREEN_ON while the hardware dashboard (or a Digital V2I
 *   intersection / vehicle screen) is open.
 * - deviceName / saveToDownloads: Digital V2I exports ("measured on <device>"), saved with
 *   MediaStore to Downloads/DigitalV2I (Android 10+; older: the app's own Downloads folder).
 * Nothing here talks to the controller; the app only listens to its WebSocket.
 */
public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.fyp.smart_traffic/hardware";

    private ConnectivityManager.NetworkCallback wifiCallback;
    private volatile Network boundNetwork;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "bindToWifi":
                            bindToWifi();
                            result.success(boundNetwork != null);
                            break;
                        case "releaseWifi":
                            releaseWifi();
                            result.success(null);
                            break;
                        case "isBoundToWifi":
                            result.success(boundNetwork != null);
                            break;
                        case "keepScreenOn":
                            final boolean on = Boolean.TRUE.equals(call.argument("on"));
                            runOnUiThread(() -> {
                                if (on) {
                                    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                                } else {
                                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                                }
                            });
                            result.success(null);
                            break;
                        case "deviceName":
                            result.success(Build.MANUFACTURER + " " + Build.MODEL + " (Android " + Build.VERSION.RELEASE + ")");
                            break;
                        case "saveToDownloads":
                            final String name = call.argument("name");
                            final String mime = call.argument("mime");
                            final byte[] bytes = call.argument("bytes");
                            new Thread(() -> {
                                try {
                                    final String where = saveToDownloads(name, mime, bytes);
                                    runOnUiThread(() -> result.success(where));
                                } catch (Exception e) {
                                    runOnUiThread(() -> result.error("SAVE_FAILED", e.getMessage(), null));
                                }
                            }).start();
                            break;
                        default:
                            result.notImplemented();
                    }
                });
    }

    /** Writes one export file; returns where it went (shown to the user). */
    private String saveToDownloads(String name, String mime, byte[] bytes) throws IOException {
        if (name == null || bytes == null) throw new IOException("nothing to save");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            final ContentResolver resolver = getContentResolver();
            final ContentValues values = new ContentValues();
            values.put(MediaStore.Downloads.DISPLAY_NAME, name);
            values.put(MediaStore.Downloads.MIME_TYPE, mime == null ? "text/plain" : mime);
            values.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DigitalV2I");
            values.put(MediaStore.Downloads.IS_PENDING, 1);
            final Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IOException("Downloads refused the file");
            try (OutputStream out = resolver.openOutputStream(uri)) {
                if (out == null) throw new IOException("cannot open the file");
                out.write(bytes);
            }
            values.clear();
            values.put(MediaStore.Downloads.IS_PENDING, 0);
            resolver.update(uri, values, null, null);
            return "Downloads/DigitalV2I/" + name;
        }
        final File dir = new File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "DigitalV2I");
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("cannot create " + dir);
        final File file = new File(dir, name);
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(bytes);
        }
        return file.getAbsolutePath();
    }

    private ConnectivityManager connectivity() {
        return (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
    }

    /** Follows the Wi-Fi network: binds when it is available, unbinds when it is lost. */
    private synchronized void bindToWifi() {
        if (wifiCallback != null) return;
        final ConnectivityManager cm = connectivity();
        if (cm == null) return;
        // Wi-Fi with or without internet access (the ESP32 network has none).
        NetworkRequest request = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build();
        wifiCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(@NonNull Network network) {
                if (cm.bindProcessToNetwork(network)) boundNetwork = network;
            }

            @Override
            public void onLost(@NonNull Network network) {
                if (network.equals(boundNetwork)) {
                    cm.bindProcessToNetwork(null);
                    boundNetwork = null;
                }
            }
        };
        try {
            cm.registerNetworkCallback(request, wifiCallback);
        } catch (RuntimeException e) {
            wifiCallback = null;
        }
    }

    private synchronized void releaseWifi() {
        final ConnectivityManager cm = connectivity();
        if (cm == null) return;
        if (wifiCallback != null) {
            try {
                cm.unregisterNetworkCallback(wifiCallback);
            } catch (RuntimeException ignored) {
                // already unregistered
            }
            wifiCallback = null;
        }
        cm.bindProcessToNetwork(null);
        boundNetwork = null;
    }

    @Override
    protected void onDestroy() {
        releaseWifi();
        super.onDestroy();
    }
}
