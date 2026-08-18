import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../constants/packet_types.dart';

/// Sealed hierarchy over the 14 PTP-IP packet types.
///
/// Every subtype knows its own [type] tag; the codec layer maps the wire
/// header to the right subclass. Payloads are Uint8List views into a
/// larger buffer, so callers must not mutate them in place.
@immutable
sealed class PtpIpPacket {
  const PtpIpPacket();

  PtpIpPacketType get type;
}

/// C→S: initial command-channel handshake.
final class InitCommandRequestPacket extends PtpIpPacket {
  const InitCommandRequestPacket({
    required this.clientGuid,
    required this.friendlyName,
    this.protocolVersionMajor = PtpIpPacketType.protocolVersionMajor,
    this.protocolVersionMinor = PtpIpPacketType.protocolVersionMinor,
  }) : assert(clientGuid.length == 16, 'GUID must be 16 bytes');

  final Uint8List clientGuid;
  final String friendlyName;
  final int protocolVersionMajor;
  final int protocolVersionMinor;

  @override
  PtpIpPacketType get type => PtpIpPacketType.initCommandRequest;
}

/// S→C: init-command handshake accepted.
final class InitCommandAckPacket extends PtpIpPacket {
  const InitCommandAckPacket({
    required this.connectionNumber,
    required this.serverGuid,
    required this.serverName,
    required this.protocolVersionMajor,
    required this.protocolVersionMinor,
  });

  final int connectionNumber;
  final Uint8List serverGuid;
  final String serverName;
  final int protocolVersionMajor;
  final int protocolVersionMinor;

  @override
  PtpIpPacketType get type => PtpIpPacketType.initCommandAck;
}

/// C→S: attach event socket to an already-acked command connection.
final class InitEventRequestPacket extends PtpIpPacket {
  const InitEventRequestPacket({required this.connectionNumber});

  final int connectionNumber;

  @override
  PtpIpPacketType get type => PtpIpPacketType.initEventRequest;
}

/// S→C: event-channel handshake accepted (body is empty).
final class InitEventAckPacket extends PtpIpPacket {
  const InitEventAckPacket();

  @override
  PtpIpPacketType get type => PtpIpPacketType.initEventAck;
}

/// S→C: init handshake rejected.
final class InitFailPacket extends PtpIpPacket {
  const InitFailPacket({required this.reason});

  final int reason;

  @override
  PtpIpPacketType get type => PtpIpPacketType.initFail;
}

/// C→S: operation request (opcode + up to 5 parameters).
final class CmdRequestPacket extends PtpIpPacket {
  const CmdRequestPacket({
    required this.dataPhaseInfo,
    required this.opcode,
    required this.transactionId,
    required this.params,
  });

  /// 1 = command has no data phase, 2 = data-out phase (host → device),
  /// values here follow the PIMA 15740 PTP-IP addendum.
  final int dataPhaseInfo;
  final int opcode;
  final int transactionId;
  final List<int> params;

  @override
  PtpIpPacketType get type => PtpIpPacketType.cmdRequest;
}

/// S→C: operation response (response code + up to 5 return params).
final class CmdResponsePacket extends PtpIpPacket {
  const CmdResponsePacket({
    required this.responseCode,
    required this.transactionId,
    required this.params,
  });

  final int responseCode;
  final int transactionId;
  final List<int> params;

  @override
  PtpIpPacketType get type => PtpIpPacketType.cmdResponse;
}

/// S→C: asynchronous camera event.
final class EventPacket extends PtpIpPacket {
  const EventPacket({
    required this.eventCode,
    required this.transactionId,
    required this.params,
  });

  final int eventCode;
  final int transactionId;
  final List<int> params;

  @override
  PtpIpPacketType get type => PtpIpPacketType.event;
}

/// Data phase — start marker with total payload length.
final class StartDataPacket extends PtpIpPacket {
  const StartDataPacket({
    required this.transactionId,
    required this.totalDataLength,
  });

  final int transactionId;
  final int totalDataLength;

  @override
  PtpIpPacketType get type => PtpIpPacketType.startData;
}

/// Data phase — intermediate chunk.
final class DataPacket extends PtpIpPacket {
  const DataPacket({required this.transactionId, required this.payload});

  final int transactionId;
  final Uint8List payload;

  @override
  PtpIpPacketType get type => PtpIpPacketType.data;
}

/// Data phase — terminator (may carry the final chunk of payload).
final class EndDataPacket extends PtpIpPacket {
  const EndDataPacket({required this.transactionId, required this.payload});

  final int transactionId;
  final Uint8List payload;

  @override
  PtpIpPacketType get type => PtpIpPacketType.endData;
}

/// C→S: cancel an in-flight transaction.
final class CancelTransactionPacket extends PtpIpPacket {
  const CancelTransactionPacket({required this.transactionId});

  final int transactionId;

  @override
  PtpIpPacketType get type => PtpIpPacketType.cancelTransaction;
}

/// C→S: keepalive on the event socket.
final class PingPacket extends PtpIpPacket {
  const PingPacket();

  @override
  PtpIpPacketType get type => PtpIpPacketType.ping;
}

/// S→C: response to a keepalive ping.
final class PongPacket extends PtpIpPacket {
  const PongPacket();

  @override
  PtpIpPacketType get type => PtpIpPacketType.pong;
}
