import 'dart:async';
import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';

/// iOS ICCameraDevice transport (iPhone USB-C + iPad USB-C/Lightning).
///
/// TODO(M6): wire to a Pigeon platform channel calling
/// `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`.
/// Events are surfaced from `ICCameraDeviceDelegate` callbacks.
///
/// Scaffolding only for now — see PLAN.md §M6.
final class IccTransport implements Transport {
  IccTransport();

  final StreamController<CameraEvent> _events =
      StreamController<CameraEvent>.broadcast();
  final StreamController<TransportState> _states =
      StreamController<TransportState>.broadcast();
  TransportState _state = TransportState.idle;

  @override
  TransportChannel get channel => TransportChannel.icc;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateChanges => _states.stream;

  @override
  Stream<CameraEvent> get events => _events.stream;

  @override
  Future<void> open(TransportConfig config) async {
    throw const PtpTransportException(
      'IccTransport not implemented — targeted for M6',
    );
  }

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    throw const PtpTransportException('IccTransport not implemented');
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) async* {
    throw const PtpTransportException('IccTransport not implemented');
  }

  @override
  Future<void> close() async {
    if (_state == TransportState.closed) return;
    _state = TransportState.closed;
    if (!_states.isClosed) _states.add(_state);
    await _events.close();
    await _states.close();
  }
}
