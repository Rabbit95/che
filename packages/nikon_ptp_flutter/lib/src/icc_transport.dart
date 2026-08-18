import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'pigeon/icc_ptp.g.dart';

/// iOS ICCameraDevice transport (iPhone USB-C + iPad USB-C/Lightning).
///
/// Bridges the pure-Dart [Transport] contract to Apple's ImageCaptureCore
/// via the pigeon-generated [IccPtpHostApi]. Session lifecycle
/// (OpenSession / CloseSession) is intercepted at the pigeon boundary and
/// answered synthetically — ICA manages its own PTP session, so PtpSession's
/// standard opcodes would double-open and blow up with 0x201E.
///
/// Transaction ids start at 1 and are monotonically increasing per session,
/// matching the USB / Wi-Fi transports.
final class IccTransport implements Transport {
  IccTransport({IccPtpHostApi? api}) : _api = api ?? IccPtpHostApi();

  final IccPtpHostApi _api;

  final StreamController<CameraEvent> _events =
      StreamController<CameraEvent>.broadcast();
  final StreamController<TransportState> _states =
      StreamController<TransportState>.broadcast();

  TransportState _state = TransportState.idle;
  int _nextTxId = 1;
  String? _iccDeviceId;

  @override
  TransportChannel get channel => TransportChannel.icc;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateChanges => _states.stream;

  @override
  Stream<CameraEvent> get events => _events.stream;

  void _setState(TransportState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> open(TransportConfig config) async {
    if (_state == TransportState.ready) return;
    final deviceId = config.iccDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw const PtpTransportException(
        'IccTransport.open requires TransportConfig.icc(iccDeviceId: ...)',
      );
    }
    _setState(TransportState.connecting);
    try {
      final ok = await _api.openSession(deviceId);
      if (!ok) {
        _setState(TransportState.failed);
        throw const PtpTransportException(
          'ICCameraDevice.requestOpenSession returned false',
        );
      }
      _iccDeviceId = deviceId;
      _setState(TransportState.ready);
    } on PlatformException catch (e) {
      _setState(TransportState.failed);
      throw PtpTransportException(
        'ICA openSession failed: ${e.message ?? e.code}',
      );
    }
  }

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    if (_state != TransportState.ready) {
      throw const PtpTransportException(
        'IccTransport.sendTransaction called before open()',
      );
    }
    final txId = _nextTxId++;
    final cmd = PtpCommand(
      opcode: transaction.opcode,
      transactionId: txId,
      params: transaction.params,
      outData: transaction.dataOut == null
          ? null
          : Uint8List.fromList(transaction.dataOut!),
    );

    Future<PtpCommandResult> call() => _api.sendCommand(cmd);
    final future = timeout == null ? call() : call().timeout(timeout);

    PtpCommandResult result;
    try {
      result = await future;
    } on TimeoutException {
      throw PtpTimeoutException(
        'IccTransport sendTransaction (opcode 0x'
        '${transaction.opcode.toRadixString(16).toUpperCase().padLeft(4, '0')}) '
        'timed out',
      );
    } on PlatformException catch (e) {
      throw PtpTransportException(
        'ICA sendCommand failed: ${e.message ?? e.code}',
      );
    }

    return PtpResponse(
      code: result.responseCode,
      params: List<int>.unmodifiable(result.responseParams),
      data: result.data,
    );
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) async* {
    // ICA has no per-chunk streaming boundary — the entire data-IN payload
    // arrives in one callback. Mirror the USB transport: run once, yield
    // the whole buffer. Higher layers slice with GetPartialObjectEx.
    final response = await sendTransaction(
      transaction,
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data != null && data.isNotEmpty) yield data;
  }

  @override
  Future<void> close() async {
    if (_state == TransportState.closed) return;
    _setState(TransportState.closing);
    try {
      await _api.closeSession();
    } on PlatformException {
      // Best-effort — camera may already be gone.
    }
    _iccDeviceId = null;
    _setState(TransportState.closed);
    if (!_events.isClosed) await _events.close();
    if (!_states.isClosed) await _states.close();
  }
}
