/// An error from the backend (with its stable `code`) or from the network.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const [],
  });

  factory ApiException.network(Object error) => ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Cannot reach the server. Check the connection and the server address.',
      );

  final int statusCode;
  final String code;
  final String message;
  final List<Map<String, dynamic>> details;

  bool get isNetwork => statusCode == 0;
  bool get isServerError => statusCode >= 500;
  bool get isRateLimited => statusCode == 429;
  bool get isAuth => statusCode == 401;

  /// Validation details joined into one readable line, when the server sent any.
  String get detailText => details
      .map((d) => (d['message'] ?? d['issue'] ?? '').toString())
      .where((m) => m.isNotEmpty)
      .join('\n');

  String get userMessage => detailText.isEmpty ? message : '$message\n$detailText';

  @override
  String toString() => 'ApiException($statusCode $code: $message)';
}
