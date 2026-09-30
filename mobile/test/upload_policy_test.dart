import 'package:flutter_test/flutter_test.dart';
import 'package:smart_traffic/core/network/api_exception.dart';
import 'package:smart_traffic/services/upload_policy.dart';

ApiException err(int status, [String code = 'X']) => ApiException(statusCode: status, code: code, message: 'm');

void main() {
  test('exponential backoff capped at 30 s', () {
    expect(UploadPolicy.backoff(0), Duration.zero);
    expect(UploadPolicy.backoff(1).inSeconds, 2);
    expect(UploadPolicy.backoff(3).inSeconds, 8);
    expect(UploadPolicy.backoff(10).inSeconds, 30);
  });

  test('network, server and rate-limit errors keep the packets', () {
    expect(UploadPolicy.classify(ApiException.network('x')), UploadAction.retryLater);
    expect(UploadPolicy.classify(err(503)), UploadAction.retryLater);
    expect(UploadPolicy.classify(err(429)), UploadAction.retryLater);
  });

  test('a closed session or unbound phone stops tracking', () {
    expect(UploadPolicy.classify(err(409, 'SESSION_NOT_ACTIVE')), UploadAction.stopTracking);
    expect(UploadPolicy.classify(err(409, 'DEVICE_NOT_BOUND')), UploadAction.stopTracking);
    expect(UploadPolicy.stopMessage(err(409, 'DEVICE_NOT_BOUND')), contains('no longer linked'));
  });

  test('a malformed batch is dropped so it cannot block the queue', () {
    expect(UploadPolicy.classify(err(422, 'VALIDATION_ERROR')), UploadAction.dropBatch);
  });

  test('packets older than the backfill window are too old', () {
    final now = DateTime.utc(2026, 9, 30, 12);
    expect(UploadPolicy.isTooOld(now.subtract(const Duration(minutes: 9)), now), isFalse);
    expect(UploadPolicy.isTooOld(now.subtract(const Duration(minutes: 10)), now), isTrue);
  });
}
