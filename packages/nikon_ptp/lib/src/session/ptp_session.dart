import 'dart:async';
import 'dart:typed_data';

import '../constants/response_codes.dart';
import '../constants/standard_opcodes.dart';
import '../errors/ptp_errors.dart';
import '../model/camera_event.dart';
import '../model/ptp_transaction.dart';
import '../transport/cancel_token.dart';
import '../transport/transport.dart';
import 'operation_queue.dart';

/// Session lifecycle state, surfaced to UI via Riverpod providers.
enum SessionState { closed, opening, open, closing, failed }

/// PTP session over a single [Transport].
///
/// Owns the transaction-id counter, the priority operation queue, and the
/// mapping from OpenSession/CloseSession → transport lifecycle.
final class PtpSession {
  PtpSession({
    required this.transport,
    int sessionId = 1,
  }) : _sessionId = sessionId;

  final Transport transport;
  final int _sessionId;

  final OperationQueue _queue = OperationQueue(name: 'ptp-session');

  final StreamController<SessionState> _stateCtl =
      StreamController<SessionState>.broadcast();

  SessionState _state = SessionState.closed;
  SessionState get state => _state;
  Stream<SessionState> get stateChanges => _stateCtl.stream;

  Stream<CameraEvent> get events => transport.events;

  Future<void> open() async {
    _setState(SessionState.opening);
    try {
      final response = await _execute(
        PtpTransaction(
          opcode: StandardOpcode.openSession,
          params: [_sessionId],
        ),
        priority: OpPriority.critical,
      );
      if (!PtpResponseCode.isOk(response.code) &&
          response.code != PtpResponseCode.sessionAlreadyOpen) {
        throw PtpResponseException(
          response.code,
          opcode: StandardOpcode.openSession,
          context: 'OpenSession failed',
        );
      }
      _setState(SessionState.open);
    } catch (e) {
      _setState(SessionState.failed);
      rethrow;
    }
  }

  Future<void> close({bool sendCloseSession = true}) async {
    if (_state == SessionState.closed) return;
    _setState(SessionState.closing);
    if (sendCloseSession) {
      try {
        await _execute(
          const PtpTransaction(opcode: StandardOpcode.closeSession),
          priority: OpPriority.critical,
        );
      } catch (_) {
        // Best-effort. The transport is being torn down anyway.
      }
    }
    await _queue.close();
    _setState(SessionState.closed);
    await _stateCtl.close();
  }

  /// Run one PTP command; returns the parsed response.
  ///
  /// [priority] governs where it sits in the queue relative to other
  /// operations (Live View frames, keepalives, etc).
  Future<PtpResponse> execute(
    PtpTransaction transaction, {
    OpPriority priority = OpPriority.normal,
    CancelToken? cancelToken,
    Duration? timeout,
  }) {
    return _execute(
      transaction,
      priority: priority,
      cancelToken: cancelToken,
      timeout: timeout,
    );
  }

  /// Run a data-in command that yields payload as a stream (Live View,
  /// large downloads). The runner still holds the transport for the duration.
  Stream<Uint8List> stream(
    PtpTransaction transaction, {
    OpPriority priority = OpPriority.low,
    CancelToken? cancelToken,
  }) {
    // A stream can't ride the operation-queue future contract directly;
    // wrap in a controller and submit the pump as a queued op.
    final ctl = StreamController<Uint8List>();
    _queue.submit<void>(
      () async {
        try {
          await for (final chunk in transport.streamTransaction(
            transaction,
            cancelToken: cancelToken,
          )) {
            if (ctl.isClosed) return;
            ctl.add(chunk);
          }
          await ctl.close();
        } catch (e, st) {
          if (!ctl.isClosed) {
            ctl.addError(e, st);
            await ctl.close();
          }
        }
      },
      priority: priority,
      cancelToken: cancelToken,
    );
    return ctl.stream;
  }

  Future<PtpResponse> _execute(
    PtpTransaction transaction, {
    OpPriority priority = OpPriority.normal,
    CancelToken? cancelToken,
    Duration? timeout,
  }) {
    return _queue.submit<PtpResponse>(
      () => transport.sendTransaction(
        transaction,
        cancelToken: cancelToken,
        timeout: timeout,
      ),
      priority: priority,
      cancelToken: cancelToken,
    );
  }

  void _setState(SessionState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateCtl.isClosed) _stateCtl.add(newState);
  }
}
