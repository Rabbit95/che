import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';

import 'client_guid_store.dart';

/// PTP-IP over TCP: cmd socket + event socket + full handshake.
///
/// Owns two sockets to `host:15740`:
///   - Command socket: request/response and data phase.
///   - Event socket: async camera events (ObjectAdded etc).
///
/// This class is Flutter-agnostic apart from [ClientGuidStore] (which uses
/// shared_preferences). If you need to test the transport headlessly, pass
/// a pre-generated GUID via the constructor.
final class PtpIpTransport implements Transport {
  PtpIpTransport({ClientGuidStore? guidStore, Uint8List? overrideGuid})
      : _guidStore = guidStore ?? ClientGuidStore(),
        _overrideGuid = overrideGuid;

  final ClientGuidStore _guidStore;
  final Uint8List? _overrideGuid;

  Socket? _cmdSocket;
  Socket? _eventSocket;
  PacketFramer? _cmdFramer;
  PacketFramer? _eventFramer;
  StreamSubscription<PtpIpPacket>? _cmdFramerSub;
  StreamSubscription<PtpIpPacket>? _eventFramerSub;
  StreamSubscription<List<int>>? _cmdBytesSub;
  StreamSubscription<List<int>>? _eventBytesSub;

  int _connectionNumber = 0;
  int _transactionId = 0;

  Completer<PtpIpPacket>? _cmdWaiter;
  final List<Uint8List> _dataBuffer = <Uint8List>[];

  final StreamController<CameraEvent> _eventsCtl =
      StreamController<CameraEvent>.broadcast();
  final StreamController<TransportState> _stateCtl =
      StreamController<TransportState>.broadcast();

  TransportState _state = TransportState.idle;

  @override
  TransportChannel get channel => TransportChannel.wifi;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateChanges => _stateCtl.stream;

  @override
  Stream<CameraEvent> get events => _eventsCtl.stream;

  @override
  Future<void> open(TransportConfig config) async {
    if (config.channel != TransportChannel.wifi) {
      throw ArgumentError.value(
        config.channel,
        'config.channel',
        'PtpIpTransport requires channel=wifi',
      );
    }
    final host = config.host;
    if (host == null) {
      throw ArgumentError.notNull('config.host');
    }
    final port = config.port ?? 15740;
    _setState(TransportState.connecting);
    try {
      final guid = _overrideGuid ?? await _guidStore.readOrCreate();
      await _openCommandSocket(host, port, guid, config.friendlyName);
      await _openEventSocket(host, port);
      _setState(TransportState.ready);
    } catch (e) {
      await close();
      _setState(TransportState.failed);
      rethrow;
    }
  }

  Future<void> _openCommandSocket(
    String host,
    int port,
    Uint8List guid,
    String friendlyName,
  ) async {
    final sock = await Socket.connect(host, port,
        timeout: const Duration(seconds: 8));
    sock.setOption(SocketOption.tcpNoDelay, true);
    _cmdSocket = sock;

    final framer = PacketFramer();
    _cmdFramer = framer;
    _cmdBytesSub = sock.listen(
      framer.feed,
      onError: (Object e, StackTrace st) => _handleFatal(e, st),
      onDone: () => _handleFatal(
        const PtpTransportException('command socket closed'),
        StackTrace.current,
      ),
      cancelOnError: true,
    );
    _cmdFramerSub = framer.stream.listen(_onCmdPacket);

    // Send InitCommandRequest and wait for ack.
    final req = InitCommandRequestPacket(
      clientGuid: guid,
      friendlyName: friendlyName,
    );
    sock.add(PtpIpCodec.encode(req));
    await sock.flush();

    final ack = await _awaitCmd(const Duration(seconds: 5));
    switch (ack) {
      case InitCommandAckPacket(:final connectionNumber):
        _connectionNumber = connectionNumber;
      case InitFailPacket(:final reason):
        throw PtpIpInitFailException(reason);
      default:
        throw PtpProtocolException(
          'unexpected init reply: ${ack.runtimeType}',
        );
    }
  }

  Future<void> _openEventSocket(String host, int port) async {
    final sock = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5));
    sock.setOption(SocketOption.tcpNoDelay, true);
    _eventSocket = sock;

    final framer = PacketFramer();
    _eventFramer = framer;
    _eventBytesSub = sock.listen(
      framer.feed,
      onError: (Object e, StackTrace st) => _handleFatal(e, st),
      onDone: () {},
      cancelOnError: true,
    );
    _eventFramerSub = framer.stream.listen(_onEventPacket);

    sock.add(PtpIpCodec.encode(
      InitEventRequestPacket(connectionNumber: _connectionNumber),
    ));
    await sock.flush();

    // The Nikon Z acks event init synchronously; wait for it here so the
    // caller sees a clean "ready" state.
    final completer = Completer<PtpIpPacket>();
    late StreamSubscription<PtpIpPacket> peek;
    peek = framer.stream.listen((pkt) {
      if (!completer.isCompleted) completer.complete(pkt);
    });
    try {
      final ack = await completer.future.timeout(const Duration(seconds: 5));
      if (ack is! InitEventAckPacket) {
        throw PtpProtocolException(
          'unexpected event init reply: ${ack.runtimeType}',
        );
      }
    } finally {
      await peek.cancel();
    }
  }

  void _onCmdPacket(PtpIpPacket pkt) {
    switch (pkt) {
      case StartDataPacket():
        _dataBuffer.clear();
      case DataPacket(:final payload):
        _dataBuffer.add(payload);
      case EndDataPacket(:final payload):
        _dataBuffer.add(payload);
      case CmdResponsePacket() || InitCommandAckPacket() || InitFailPacket():
        final w = _cmdWaiter;
        _cmdWaiter = null;
        if (w != null && !w.isCompleted) w.complete(pkt);
      case PongPacket():
        // ignore
        break;
      default:
        // Unexpected on cmd socket — ignore.
        break;
    }
  }

  void _onEventPacket(PtpIpPacket pkt) {
    if (pkt is EventPacket) {
      _eventsCtl.add(CameraEvent(
        code: pkt.eventCode,
        transactionId: pkt.transactionId,
        p1: pkt.params.isNotEmpty ? pkt.params[0] : 0,
        p2: pkt.params.length > 1 ? pkt.params[1] : 0,
        p3: pkt.params.length > 2 ? pkt.params[2] : 0,
      ));
    }
  }

  Future<PtpIpPacket> _awaitCmd(Duration timeout) {
    final c = Completer<PtpIpPacket>();
    _cmdWaiter = c;
    return c.future.timeout(timeout, onTimeout: () {
      _cmdWaiter = null;
      throw const PtpTimeoutException('command socket idle timeout');
    });
  }

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    final sock = _cmdSocket;
    if (sock == null || _state != TransportState.ready) {
      throw const PtpTransportException('transport not ready');
    }
    final txId = ++_transactionId;
    final dataPhaseInfo = switch (transaction.dataPhase) {
      PtpDataPhase.none => 1,
      PtpDataPhase.dataOut => 2,
      PtpDataPhase.dataIn => 1,
    };

    _dataBuffer.clear();

    // 1. Send the CmdRequest.
    final cmdPkt = CmdRequestPacket(
      dataPhaseInfo: dataPhaseInfo,
      opcode: transaction.opcode,
      transactionId: txId,
      params: transaction.params,
    );
    sock.add(PtpIpCodec.encode(cmdPkt));

    // 2. Data-out phase (host → device) if the transaction carries payload.
    if (transaction.dataPhase == PtpDataPhase.dataOut &&
        transaction.dataOut != null) {
      final payload = transaction.dataOut!;
      sock.add(PtpIpCodec.encode(
        StartDataPacket(transactionId: txId, totalDataLength: payload.length),
      ));
      sock.add(PtpIpCodec.encode(
        EndDataPacket(transactionId: txId, payload: payload),
      ));
    }

    await sock.flush();

    // 3. Await the CmdResponse (accumulating data-in via _onCmdPacket).
    final reply = await _awaitCmd(timeout ?? const Duration(seconds: 30));
    if (reply is! CmdResponsePacket) {
      throw PtpProtocolException(
        'expected CmdResponse, got ${reply.runtimeType}',
      );
    }
    if (reply.transactionId != txId) {
      throw PtpProtocolException(
        'transaction id mismatch (sent $txId, got ${reply.transactionId})',
      );
    }

    final data = _dataBuffer.isEmpty
        ? null
        : Uint8List.fromList(_dataBuffer.expand((c) => c).toList(growable: false));
    _dataBuffer.clear();

    return PtpResponse(
      code: reply.responseCode,
      params: reply.params,
      data: data,
    );
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) async* {
    // Wi-Fi framing doesn't naturally chunk-emit — send the transaction
    // once and yield the buffered payload as one chunk. Callers wanting
    // fine-grained chunking use GetPartialObjectEx from NikonZClient.
    final r = await sendTransaction(transaction, cancelToken: cancelToken);
    if (r.data != null && r.data!.isNotEmpty) {
      yield r.data!;
    }
  }

  void _setState(TransportState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateCtl.isClosed) _stateCtl.add(newState);
  }

  void _handleFatal(Object e, StackTrace st) {
    if (_state == TransportState.closed) return;
    _setState(TransportState.failed);
    final waiter = _cmdWaiter;
    _cmdWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(e, st);
  }

  @override
  Future<void> close() async {
    if (_state == TransportState.closed) return;
    _setState(TransportState.closing);
    await _cmdFramerSub?.cancel();
    await _eventFramerSub?.cancel();
    await _cmdBytesSub?.cancel();
    await _eventBytesSub?.cancel();
    await _cmdFramer?.close();
    await _eventFramer?.close();
    try {
      await _cmdSocket?.close();
    } catch (_) {}
    try {
      await _eventSocket?.close();
    } catch (_) {}
    _cmdSocket = null;
    _eventSocket = null;
    _cmdFramer = null;
    _eventFramer = null;
    _cmdFramerSub = null;
    _eventFramerSub = null;
    _cmdBytesSub = null;
    _eventBytesSub = null;
    _setState(TransportState.closed);
    await _eventsCtl.close();
    await _stateCtl.close();
  }
}
