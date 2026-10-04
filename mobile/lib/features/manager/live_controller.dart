import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../data/models/control.dart';
import '../../data/models/emergency.dart';
import '../../data/models/json.dart';
import '../../data/models/telemetry.dart';
import '../../data/models/traffic.dart';
import '../../data/repositories/manager_repository.dart';

enum LiveConnection { connecting, live, polling, offline }

class LiveEvent {
  LiveEvent(this.type, this.data);
  final String type; // EMERGENCY_STARTED, EMERGENCY_ENDED, AUTHORIZATION_REQUESTED, MODE_CHANGED
  final Json data;
}

class TrendPoint {
  TrendPoint(this.time, this.transmitting, this.avgSpeedMps, this.congested);
  final DateTime time;
  final int transmitting;
  final double? avgSpeedMps;
  final int congested;
}

/// Live traffic picture for managers. WebSocket push first; REST polling as a fallback.
class LiveController extends ChangeNotifier {
  LiveController(this._api, this._repo);

  static const pollInterval = Duration(seconds: 5);
  static const trendWindow = Duration(minutes: 30);

  final ApiClient _api;
  final ManagerRepository _repo;
  final _events = StreamController<LiveEvent>.broadcast();

  TrafficOverview? overview;
  List<LiveVehicle> _vehicles = [];
  List<IntersectionTraffic> intersections = [];
  List<ActiveEmergency> emergencies = [];
  final List<TrendPoint> trend = [];
  DateTime? lastUpdate;
  LiveConnection connection = LiveConnection.connecting;
  String? error;
  bool includeSimulated = true;

  /// Recent fixed-time / adaptive / emergency mode changes, newest first.
  List<ModeEvent> modeEvents = [];
  ControlConfig? controlConfig;

  /// Server clock minus phone clock, so signal countdowns are right even if the phone's
  /// clock is off.
  Duration _serverOffset = Duration.zero;
  DateTime get serverNow => DateTime.now().toUtc().add(_serverOffset);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  int _failures = 0;
  bool _running = false;

  Stream<LiveEvent> get events => _events.stream;

  List<LiveVehicle> get vehicles => includeSimulated ? _vehicles : _vehicles.where((v) => !v.isSimulated).toList();
  List<LiveVehicle> get allVehicles => _vehicles;

  void setIncludeSimulated(bool value) {
    includeSimulated = value;
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await refresh(); // show data immediately, before the first push
    unawaited(_loadControl());
    _connect();
  }

  Future<void> _loadControl() async {
    try {
      final results = await Future.wait([_repo.modeEvents(limit: 30), _repo.controlConfig()]);
      modeEvents = results[0] as List<ModeEvent>;
      controlConfig = results[1] as ControlConfig;
      notifyListeners();
    } on ApiException {
      // Older servers do not have these endpoints; the dashboard works without them.
    }
  }

  void _setServerTime(DateTime? serverTime) {
    if (serverTime != null) _serverOffset = serverTime.difference(DateTime.now().toUtc());
  }

  void stop() {
    _running = false;
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  /// One REST round trip for everything the live views need.
  Future<void> refresh() async {
    try {
      final results = await Future.wait([
        _repo.overview(),
        _repo.liveVehicles(),
        _repo.trafficIntersections(),
        _repo.activeEmergencies(),
      ]);
      overview = results[0] as TrafficOverview;
      _setServerTime(overview!.generatedAt);
      _vehicles = results[1] as List<LiveVehicle>;
      intersections = results[2] as List<IntersectionTraffic>;
      emergencies = results[3] as List<ActiveEmergency>;
      _afterUpdate();
      error = null;
      if (connection == LiveConnection.polling) unawaited(_loadControl()); // no live mode events while polling
    } on ApiException catch (e) {
      error = e.message;
      if (e.isNetwork) connection = LiveConnection.offline;
    }
    notifyListeners();
  }

  void _afterUpdate() {
    lastUpdate = DateTime.now();
    final o = overview;
    if (o == null) return;
    final now = DateTime.now();
    if (trend.isEmpty || now.difference(trend.last.time) >= const Duration(seconds: 10)) {
      trend.add(TrendPoint(now, o.transmittingVehicles, o.averageSpeedMps, o.congestedIntersections));
      trend.removeWhere((p) => now.difference(p.time) > trendWindow);
    }
  }

  Future<void> _connect() async {
    if (!_running) return;
    final token = _api.accessToken;
    if (token == null) return;
    connection = _failures >= 3 ? LiveConnection.polling : LiveConnection.connecting;
    notifyListeners();
    try {
      final channel = WebSocketChannel.connect(_api.liveSocketUri());
      await channel.ready.timeout(const Duration(seconds: 10));
      _channel = channel;
      channel.sink.add(jsonEncode({'type': 'auth', 'accessToken': token}));
      _sub = channel.stream.listen(
        _onMessage,
        onDone: () => _onClosed(channel.closeCode),
        onError: (_) => _onClosed(null),
        cancelOnError: true,
      );
    } catch (_) {
      _onClosed(null);
    }
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Json;
    switch (msg['type']) {
      case 'hello':
        _failures = 0;
        connection = LiveConnection.live;
        _pollTimer?.cancel();
      case 'snapshot':
        _setServerTime(parseTime(msg['serverTime']));
        overview = TrafficOverview(msg['summary'] as Json);
        _vehicles = jsonList(msg['vehicles']).map(LiveVehicle.fromJson).toList();
        intersections = jsonList(msg['intersections']).map(IntersectionTraffic.new).toList();
        emergencies = jsonList(msg['emergencies']).map(ActiveEmergency.new).toList();
        connection = LiveConnection.live;
        _afterUpdate();
      case 'event':
        final type = msg['event'] as String;
        _events.add(LiveEvent(type, msg));
        if (type == 'MODE_CHANGED') {
          modeEvents = [ModeEvent.fromLive(msg), ...modeEvents].take(50).toList();
        } else {
          unawaited(refresh());
        }
    }
    notifyListeners();
  }

  Future<void> _onClosed(int? code) async {
    _sub?.cancel();
    _channel = null;
    if (!_running) return;
    if (code == 4401) {
      // Access token expired: refresh it, then reconnect straight away.
      try {
        if (await _api.refresh()) {
          _connect();
          return;
        }
      } on ApiException {
        // fall through to backoff
      }
    }
    _failures++;
    if (_failures >= 3 && (_pollTimer == null || !_pollTimer!.isActive)) {
      connection = LiveConnection.polling;
      _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
    }
    notifyListeners();
    final delay = Duration(seconds: _failures < 3 ? 2 * _failures : 30);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _connect);
  }

  @override
  void dispose() {
    stop();
    _events.close();
    super.dispose();
  }
}
