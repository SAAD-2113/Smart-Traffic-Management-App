import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'packet_builder.dart';

enum LocationAccess { granted, denied, deniedForever, serviceDisabled, unsupported }

/// Wraps the geolocator plugin so the rest of the app never touches it directly.
class LocationService {
  Future<LocationAccess> ensureAccess() async {
    if (kIsWeb) return LocationAccess.unsupported;
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    return switch (permission) {
      LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      _ => LocationAccess.denied,
    };
  }

  /// About one fix per second, delivered through an Android foreground service so tracking
  /// continues with the screen off. The persistent notification tells the driver it is on.
  Stream<GpsFix> fixes({required String notificationTitle, required String notificationText}) {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    );
    return Geolocator.getPositionStream(locationSettings: settings).map(
      (p) => GpsFix(
        time: p.timestamp.toUtc(),
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: p.accuracy,
        speedMps: p.speed,
        speedAccuracyMps: p.speedAccuracy,
        headingDeg: p.heading,
        altitudeM: p.altitude,
        mocked: p.isMocked,
      ),
    );
  }

  Stream<bool> serviceEnabledChanges() =>
      Geolocator.getServiceStatusStream().map((s) => s == ServiceStatus.enabled);

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
