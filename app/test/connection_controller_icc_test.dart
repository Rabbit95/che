import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'package:nikon_z_control/features/connection/connection_controller.dart';

/// Verifies that a `PtpTimeoutException` bubbling up from the ICC transport
/// gets translated into the ICC-specific user-facing message rather than
/// the historical Wi-Fi copy ("检查手机是否已连接到相机 Wi-Fi").
///
/// Uses a hand-rolled fake `Transport` — we do NOT want to spin up a real
/// `IccTransport` here because that would require the pigeon binary
/// messenger, and the point of this test is the string dispatch inside
/// `ConnectionController._driveHandshake`.
void main() {
  test(
    'connectIcc: PtpTimeoutException → ICC-specific message with 有线配件 hint',
    () async {
      final controller = ConnectionController(
        transportFactory: (_) =>
            _TimingOutTransport(TransportChannel.icc),
      );

      final events = await controller
          .connectIcc(iccDeviceId: 'icc-x', friendlyName: 'test')
          .toList();

      final failed = events.whereType<ConnectionFailed>().single;
      expect(failed.message, contains('ICA'));
      expect(failed.message, contains('有线配件'));
      // Regression guard: the Wi-Fi copy must not leak into ICC failures.
      expect(failed.message, isNot(contains('相机 Wi-Fi')));
    },
  );

  test(
    'connectWifi: PtpTimeoutException still uses Wi-Fi copy (no regression)',
    () async {
      final controller = ConnectionController(
        transportFactory: (_) =>
            _TimingOutTransport(TransportChannel.wifi),
      );

      final events = await controller
          .connectWifi(host: '10.0.0.1')
          .toList();

      final failed = events.whereType<ConnectionFailed>().single;
      expect(
        failed.message,
        anyOf(
          contains('相机 IP'),
          contains('相机 Wi-Fi'),
        ),
      );
    },
  );
}

/// Minimal Transport whose `open()` immediately throws PtpTimeoutException.
/// Everything else is a no-op / SUT-invariant.
class _TimingOutTransport implements Transport {
  _TimingOutTransport(this._channel);

  final TransportChannel _channel;

  @override
  TransportChannel get channel => _channel;

  @override
  TransportState get state => TransportState.failed;

  @override
  Stream<TransportState> get stateChanges =>
      const Stream<TransportState>.empty();

  @override
  Stream<CameraEvent> get events => const Stream<CameraEvent>.empty();

  @override
  Future<void> open(TransportConfig config) async {
    throw const PtpTimeoutException('simulated stall');
  }

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) {
    throw StateError('not reached');
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) =>
      const Stream<Uint8List>.empty();

  @override
  Future<void> close() async {}
}
