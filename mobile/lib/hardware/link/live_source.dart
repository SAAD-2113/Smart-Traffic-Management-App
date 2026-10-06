import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'frame_source.dart';

typedef SocketConnector = WebSocketChannel Function(Uri uri);

/// Read-only WebSocket client for the ESP32 (default ws://192.168.4.1:81/).
/// It only listens: nothing is ever written to the socket.
/// While disconnected it tries again every [retryDelay].
class LiveSource implements FrameSource {
  LiveSource(this.uri, {SocketConnector? connect, this.retryDelay = const Duration(seconds: 2)})
      : _connect = connect ?? WebSocketChannel.connect;

  final Uri uri;
  final Duration retryDelay;
  final SocketConnector _connect;

  /// A connection attempt that has not opened by then counts as failed.
  static const connectTimeout = Duration(seconds: 3);

  static Uri uriFor(String host, int port) => Uri(scheme: 'ws', host: host, port: port, path: '/');

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  bool _running = false;
  bool _open = false;
  int _attempt = 0;

  @override
  void Function(String text)? onFrame;

  @override
  void Function(bool open)? onOpen;

  @override
  bool get isSimulator => false;

  @override
  String get label => uri.toString();

  @override
  void start() {
    if (_running) return;
    _running = true;
    _tryConnect();
  }

  Future<void> _tryConnect() async {
    if (!_running) return;
    final attempt = ++_attempt;
    WebSocketChannel? channel;
    try {
      channel = _connect(uri);
      await channel.ready.timeout(connectTimeout);
    } catch (_) {
      _closeChannel(channel);
      if (attempt == _attempt) _scheduleRetry();
      return;
    }
    if (!_running || attempt != _attempt) {
      _closeChannel(channel);
      return;
    }
    _channel = channel;
    _setOpen(true);
    _sub = channel.stream.listen(
      (data) {
        if (data is String) {
          onFrame?.call(data);
        } else if (data is List<int>) {
          onFrame?.call(utf8.decode(data, allowMalformed: true));
        }
      },
      onError: (_) => _lost(channel!),
      onDone: () => _lost(channel!),
      cancelOnError: true,
    );
  }

  void _lost(WebSocketChannel channel) {
    if (!identical(channel, _channel)) return;
    _sub?.cancel();
    _sub = null;
    _closeChannel(channel);
    _channel = null;
    _setOpen(false);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    if (_running) _retry = Timer(retryDelay, _tryConnect);
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    _open = open;
    onOpen?.call(open);
  }

  void _closeChannel(WebSocketChannel? channel) {
    try {
      channel?.sink.close();
    } catch (_) {}
  }

  @override
  void stop() {
    _running = false;
    _attempt++;
    _retry?.cancel();
    _sub?.cancel();
    _sub = null;
    _closeChannel(_channel);
    _channel = null;
    _setOpen(false);
  }
}
