package com.fyp.smart_traffic;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.view.WindowManager;

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
 * - keepScreenOn: FLAG_KEEP_SCREEN_ON while the hardware dashboard is open.
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
                        default:
                            result.notImplemented();
                    }
                });
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
