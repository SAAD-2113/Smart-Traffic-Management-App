import 'package:flutter/foundation.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_exception.dart';
import '../../data/models/emergency.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/vehicle.dart';
import '../../data/repositories/vehicle_repository.dart';

/// The driver's vehicles, which one this phone reports for, and its emergency status.
class DriverController extends ChangeNotifier {
  DriverController(this._repo, this._config);

  static const appVersion = '1.0.0';

  final VehicleRepository _repo;
  final AppConfig _config;

  bool loading = true;
  String? error;
  List<OwnerVehicle> vehicles = [];
  OwnerVehicle? selected;
  bool phoneLinked = false; // is this installation the active device of `selected`?
  bool otherPhoneLinked = false;
  EmergencyStatus? emergency;
  List<TrackingSession> trips = [];

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      vehicles = await _repo.myVehicles();
      final saved = _config.selectedVehicleId;
      selected = vehicles.where((v) => v.id == saved).firstOrNull ?? vehicles.firstOrNull;
      if (selected != null) await _refreshSelected();
    } on ApiException catch (e) {
      error = e.userMessage;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> _refreshSelected() async {
    final v = selected!;
    final devices = await _repo.devices(v.id);
    phoneLinked = devices.any((d) => d.isActive && d.installationId == _repo.installationId);
    otherPhoneLinked = devices.any((d) => d.isActive && d.installationId != _repo.installationId);
    emergency = v.isEmergencyVehicle ? await _repo.emergencyStatus(v.id) : null;
  }

  Future<void> select(OwnerVehicle v) async {
    selected = v;
    await _config.setSelectedVehicle(v.id);
    await _refreshSelected();
    notifyListeners();
  }

  /// Makes this phone the vehicle's reporting device (any other phone stops reporting for it).
  Future<void> linkThisPhone() async {
    final v = selected;
    if (v == null) return;
    await _repo.bindThisDevice(v.id, platform: 'ANDROID', appVersion: appVersion);
    await _refreshSelected();
    notifyListeners();
  }

  Future<OwnerVehicle> registerVehicle({required String type, required String displayName, String? registrationNumber}) async {
    final v = await _repo.register(type: type, displayName: displayName, registrationNumber: registrationNumber);
    vehicles = [...vehicles, v];
    selected = v;
    await _config.setSelectedVehicle(v.id);
    await _repo.bindThisDevice(v.id, platform: 'ANDROID', appVersion: appVersion);
    await _refreshSelected();
    notifyListeners();
    return v;
  }

  Future<void> refreshEmergency() async {
    final v = selected;
    if (v == null || !v.isEmergencyVehicle) return;
    emergency = await _repo.emergencyStatus(v.id);
    notifyListeners();
  }

  Future<void> activateEmergency() async {
    await _repo.startEmergency(selected!.id);
    await refreshEmergency();
  }

  Future<void> deactivateEmergency() async {
    await _repo.stopEmergency(selected!.id);
    await refreshEmergency();
  }

  Future<void> requestAuthorization() async {
    emergency = await _repo.requestAuthorization(selected!.id);
    notifyListeners();
  }

  Future<void> loadTrips() async {
    final v = selected;
    if (v == null) return;
    trips = await _repo.sessions(v.id);
    notifyListeners();
  }
}
