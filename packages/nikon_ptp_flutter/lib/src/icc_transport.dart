import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'icc_channel.dart';
import 'pigeon/icc_ptp.g.dart';

/// A single heartbeat pushed by the Swift coordinator while an
/// [IccTransport.open] call is pending or shortly after it succeeds.
///
/// See `IccPtpFlutterApi.onSessionOpenProgress` in the pigeon schema for
/// the meaning of each [phase] value.
@immutable
final class IccOpenProgress {
  const IccOpenProgress({
    required this.deviceId,
    required this.phase,
    required this.percent,
    required this.elapsedMs,
  });

  final String deviceId;

  /// One of `'openSession' | 'catalog' | 'ready' | 'timeout'`.
  final String phase;

  /// `[0, 100]` for `catalog`; `-1` when unknown.
  final int percent;

  /// Milliseconds since the Swift side received the openSession request.
  final int elapsedMs;
}

/// A structured log line mirrored from the Swift coordinator's `os.Logger`.
/// Delivered through [IccTransport.diagnosticLogs] so the in-app "copy
/// logs" panel can surface Swift-side detail on hosts without Console.app.
@immutable
final class IccDiagnosticLog {
  const IccDiagnosticLog({
    required this.tag,
    required this.message,
    required this.elapsedMs,
  });

  /// Short kebab-case slug — see `IccPtpFlutterApi.onDiagnosticLog` docs.
  final String tag;
  final String message;

  /// Milliseconds since the pending `openSession` started, or `-1` when
  /// the event is not tied to one.
  final int elapsedMs;
}

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
///
/// Observability (Phase A): [openProgress] surfaces the heartbeats the
/// Swift coordinator emits while `requestOpenSession` is pending — this
/// is how the UI distinguishes "waiting on Apple" from "catalog is 40 %
/// scanned" from "watchdog fired". [openTimeout] guarantees the future
/// returned by [open] resolves within a bounded time; the default 120 s
/// matches the Swift-side watchdog.
final class IccTransport implements Transport {
  IccTransport({
    IccPtpHostApi? api,
    Duration openTimeout = const Duration(seconds: 120),
  })  : _api = api ?? IccPtpHostApi(),
        _openTimeout = openTimeout;

  final IccPtpHostApi _api;
  final Duration _openTimeout;

  final StreamController<CameraEvent> _events =
      StreamController<CameraEvent>.broadcast();
  final StreamController<TransportState> _states =
      StreamController<TransportState>.broadcast();
  final StreamController<IccOpenProgress> _progress =
      StreamController<IccOpenProgress>.broadcast();
  final StreamController<IccDiagnosticLog> _diagnostics =
      StreamController<IccDiagnosticLog>.broadcast();

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

  /// Progress heartbeats from the Swift coordinator during (and shortly
  /// after) [open]. Non-contract — consumed by
  /// `ConnectionController._runHandshake` when [channel] is
  /// [TransportChannel.icc].
  Stream<IccOpenProgress> get openProgress => _progress.stream;

  /// Every structured log line the Swift coordinator emits, mirrored
  /// alongside its `os.Logger`. Non-contract — the connect UI subscribes
  /// so the in-app "copy logs" panel can surface Swift-side detail.
  Stream<IccDiagnosticLog> get diagnosticLogs => _diagnostics.stream;

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
    // Subscribe to native push channel BEFORE opening the session so we
    // don't miss a stray event fired during the window.
    IccPtpChannel.instance.setPtpEventListener(_onPtpEvent);
    IccPtpChannel.instance.setSessionEndedListener(_onSessionEnded);
    IccPtpChannel.instance.setSessionOpenProgressListener(_onOpenProgress);
    IccPtpChannel.instance.setDiagnosticLogListener(_onDiagnosticLog);
    try {
      final ok = await _api.openSession(deviceId).timeout(
        _openTimeout,
        onTimeout: () {
          throw PtpTimeoutException(
            'ICA openSession 超时（${_openTimeout.inSeconds}s） '
            '— 未在时限内收到 didOpenSessionWithError 回调',
          );
        },
      );
      if (!ok) {
        _detachChannel();
        _setState(TransportState.failed);
        throw const PtpTransportException(
          'ICCameraDevice.requestOpenSession returned false',
        );
      }
      _iccDeviceId = deviceId;
      _setState(TransportState.ready);
    } on PtpTimeoutException {
      _detachChannel();
      _setState(TransportState.failed);
      rethrow;
    } on PlatformException catch (e) {
      _detachChannel();
      _setState(TransportState.failed);
      throw PtpTransportException(
        'ICA openSession failed: ${e.message ?? e.code}',
      );
    }
  }

  void _onPtpEvent(int eventCode, int transactionId, List<int> params) {
    if (_events.isClosed) return;
    _events.add(CameraEvent(
      code: eventCode,
      transactionId: transactionId,
      p1: params.isNotEmpty ? params[0] : 0,
      p2: params.length > 1 ? params[1] : 0,
      p3: params.length > 2 ? params[2] : 0,
    ));
  }

  void _onSessionEnded(String deviceId, String reason) {
    // Only react to events for our device — a listener from a stale
    // transport shouldn't hijack a fresh session.
    if (_iccDeviceId != null && deviceId != _iccDeviceId) return;
    if (_state == TransportState.closed) return;
    _detachChannel();
    _setState(TransportState.failed);
  }

  void _onOpenProgress(
    String deviceId,
    String phase,
    int percent,
    int elapsedMs,
  ) {
    if (_progress.isClosed) return;
    // Filter by device id once we know ours, so a stale coordinator event
    // from a previous session can't leak into the current UI.
    if (_iccDeviceId != null && deviceId != _iccDeviceId) return;
    _progress.add(IccOpenProgress(
      deviceId: deviceId,
      phase: phase,
      percent: percent,
      elapsedMs: elapsedMs,
    ));
  }

  void _onDiagnosticLog(String tag, String message, int elapsedMs) {
    if (_diagnostics.isClosed) return;
    // No device-id filter — diagnostic events include browser churn that
    // isn't tied to any single device. The UI can filter downstream.
    _diagnostics.add(IccDiagnosticLog(
      tag: tag,
      message: message,
      elapsedMs: elapsedMs,
    ));
  }

  /// Detach this transport from the shared channel. Safe to call
  /// repeatedly; only clears if the current listener is ours.
  void _detachChannel() {
    IccPtpChannel.instance.setPtpEventListener(null);
    IccPtpChannel.instance.setSessionEndedListener(null);
    IccPtpChannel.instance.setSessionOpenProgressListener(null);
    IccPtpChannel.instance.setDiagnosticLogListener(null);
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
    _detachChannel();
    try {
      await _api.closeSession();
    } on PlatformException {
      // Best-effort — camera may already be gone.
    }
    _iccDeviceId = null;
    _setState(TransportState.closed);
    if (!_events.isClosed) await _events.close();
    if (!_states.isClosed) await _states.close();
    if (!_progress.isClosed) await _progress.close();
    if (!_diagnostics.isClosed) await _diagnostics.close();
  }
}
