import 'dart:async';

import 'package:http/http.dart' as http;

import 'links.dart';

/// A vehicle that POSTs each pos packet to `base`/api/vehicle and gets the ACK in the response,
/// as the firmware's HTTP endpoint answers (the README's curl):
///  - HardwareBridgeTransport: base = http://192.168.4.1 (the real ESP32 junction), so phones
///    and ESP vehicles share one physical junction;
///  - LAN: base = `http://<intersection phone>:8080` (the LanIntersectionLink).
/// Every packet is sent, whether or not the previous one was answered, like a UDP beacon; the
/// vehicle shows RED after 3 s without an ACK. RTT is measured by the vehicle unit per seq.
class HttpVehicleLink extends VehicleLink {
  HttpVehicleLink(this.base, {http.Client? client, this.timeout = const Duration(milliseconds: 1500), this.what = 'LAN'})
      : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;
  final Duration timeout;

  /// "LAN" or "ESP32".
  final String what;
  bool _on = false;
  LinkState _state = LinkState.connecting;
  int failures = 0;

  @override
  bool get connectionless => true;

  @override
  String get label => '$what (${base.host}${base.hasPort ? ':${base.port}' : ''})';

  @override
  void start() {
    _on = true;
    _set(LinkState.online, null); // nothing to open: sending decides
    onIntersection?.call(true);
  }

  @override
  void stop() {
    _on = false;
    _client.close();
    _set(LinkState.closed, 'stopped');
  }

  void _set(LinkState s, String? reason) {
    if (s == _state && reason == null) return;
    _state = s;
    onState?.call(s, reason);
  }

  @override
  void send(String raw) {
    if (!_on) return;
    _post(raw);
  }

  Future<void> _post(String raw) async {
    try {
      final r = await _client
          .post(base.replace(path: '/api/vehicle'), headers: {'Content-Type': 'application/json'}, body: raw)
          .timeout(timeout);
      if (!_on) return;
      if (r.statusCode == 200) {
        failures = 0;
        _set(LinkState.online, null);
        onIntersection?.call(true);
        onAck?.call(r.body);
      } else {
        onError?.call('HTTP_${r.statusCode}', r.body);
      }
    } catch (e) {
      if (!_on) return;
      failures++;
      _set(LinkState.offline, 'No answer from ${base.host}');
      onIntersection?.call(false);
    }
  }

  @override
  void sendRtt(int ms) {} // shown on this phone; the ESP32 has no place for it
}
