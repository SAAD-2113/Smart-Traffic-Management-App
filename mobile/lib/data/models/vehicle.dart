import 'json.dart';

const vehicleTypes = ['NORMAL', 'AMBULANCE', 'FIRE_TRUCK', 'POLICE'];

String vehicleTypeLabel(String type) => switch (type) {
      'AMBULANCE' => 'Ambulance',
      'FIRE_TRUCK' => 'Fire truck',
      'POLICE' => 'Police',
      _ => 'Normal vehicle',
    };

bool isEmergencyType(String type) => type != 'NORMAL';

class OwnerVehicle {
  OwnerVehicle({
    required this.id,
    required this.code,
    required this.vehicleType,
    required this.displayName,
    required this.status,
    required this.emergencyAuthorized,
    this.registrationNumber,
    this.authorizationStatus,
    this.authorizationValidUntil,
    required this.isSimulated,
  });

  factory OwnerVehicle.fromJson(Json j) {
    final auth = j['emergencyAuthorization'] as Json?;
    return OwnerVehicle(
      id: j['id'] as String,
      code: j['code'] as String,
      vehicleType: j['vehicleType'] as String,
      displayName: j['displayName'] as String,
      registrationNumber: j['registrationNumber'] as String?,
      status: j['status'] as String,
      emergencyAuthorized: j['emergencyAuthorized'] as bool,
      authorizationStatus: auth?['status'] as String?,
      authorizationValidUntil: parseTime(auth?['validUntil']),
      isSimulated: j['isSimulated'] as bool? ?? false,
    );
  }

  final String id;
  final String code; // display label, e.g. VH-0012; the real key is `id`
  final String vehicleType;
  final String displayName;
  final String? registrationNumber;
  final String status;
  final bool emergencyAuthorized;
  final String? authorizationStatus;
  final DateTime? authorizationValidUntil;
  final bool isSimulated;

  bool get isEmergencyVehicle => isEmergencyType(vehicleType);
  bool get isActive => status == 'ACTIVE';
}

class DeviceInfo {
  DeviceInfo({required this.id, required this.installationId, required this.status, this.model, this.lastSeenAt});

  factory DeviceInfo.fromJson(Json j) => DeviceInfo(
        id: j['id'] as String,
        installationId: j['installationId'] as String,
        status: j['status'] as String,
        model: j['model'] as String?,
        lastSeenAt: parseTime(j['lastSeenAt']),
      );

  final String id;
  final String installationId;
  final String status;
  final String? model;
  final DateTime? lastSeenAt;

  bool get isActive => status == 'ACTIVE';
}
