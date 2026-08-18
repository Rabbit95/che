import 'dart:typed_data';

import '../constants/packet_types.dart';
import '../errors/ptp_errors.dart';
import '../model/ptp_ip_packet.dart';
import 'byte_reader.dart';
import 'byte_writer.dart';

/// Encode / decode for the 14 PTP-IP packet types.
///
/// Every packet on the wire is `uint32 length | uint32 type | body`.
/// [encode] returns the full buffer including the 8-byte header;
/// [decode] expects the same shape and re-tags the subclass by type.
abstract final class PtpIpCodec {
  PtpIpCodec._();

  static Uint8List encode(PtpIpPacket packet) {
    final bodyWriter = ByteWriter();
    _writeBody(packet, bodyWriter);
    final body = bodyWriter.takeBytes();

    final total = PtpIpPacketType.headerBytes + body.length;
    final out = ByteWriter()
      ..writeU32(total)
      ..writeU32(packet.type.value)
      ..writeBytes(body);
    return out.takeBytes();
  }

  static PtpIpPacket decode(Uint8List frame) {
    if (frame.length < PtpIpPacketType.headerBytes) {
      throw PtpProtocolException(
        'frame too short: ${frame.length}B < 8B header',
      );
    }
    final r = ByteReader(frame);
    final length = r.readU32();
    final typeValue = r.readU32();
    if (length != frame.length) {
      throw PtpProtocolException(
        'length mismatch: header says $length, buffer is ${frame.length}',
      );
    }
    return _decodeBody(PtpIpPacketType(typeValue), r);
  }

  // ─── body encode ────────────────────────────────────────────────

  static void _writeBody(PtpIpPacket packet, ByteWriter w) {
    switch (packet) {
      case InitCommandRequestPacket():
        if (packet.clientGuid.length != 16) {
          throw const PtpProtocolException('GUID must be 16 bytes');
        }
        w.writeBytes(packet.clientGuid);
        w.writeUtf16LeNullTerminated(packet.friendlyName);
        // Order on the wire is (minor, major).
        w.writeU16(packet.protocolVersionMinor);
        w.writeU16(packet.protocolVersionMajor);
      case InitCommandAckPacket():
        w.writeU32(packet.connectionNumber);
        w.writeBytes(packet.serverGuid);
        w.writeUtf16LeNullTerminated(packet.serverName);
        w.writeU16(packet.protocolVersionMinor);
        w.writeU16(packet.protocolVersionMajor);
      case InitEventRequestPacket():
        w.writeU32(packet.connectionNumber);
      case InitEventAckPacket():
        break;
      case InitFailPacket():
        w.writeU32(packet.reason);
      case CmdRequestPacket():
        w.writeU32(packet.dataPhaseInfo);
        w.writeU32(packet.opcode);
        w.writeU32(packet.transactionId);
        for (final p in packet.params) {
          w.writeU32(p);
        }
      case CmdResponsePacket():
        w.writeU32(packet.responseCode);
        w.writeU32(packet.transactionId);
        for (final p in packet.params) {
          w.writeU32(p);
        }
      case EventPacket():
        w.writeU32(packet.eventCode);
        w.writeU32(packet.transactionId);
        for (final p in packet.params) {
          w.writeU32(p);
        }
      case StartDataPacket():
        w.writeU32(packet.transactionId);
        // 64-bit total-length as two LE uint32 (low, high) per PTP-IP spec.
        w.writeU32(packet.totalDataLength & 0xFFFFFFFF);
        w.writeU32((packet.totalDataLength >> 32) & 0xFFFFFFFF);
      case DataPacket():
        w.writeU32(packet.transactionId);
        w.writeBytes(packet.payload);
      case EndDataPacket():
        w.writeU32(packet.transactionId);
        w.writeBytes(packet.payload);
      case CancelTransactionPacket():
        w.writeU32(packet.transactionId);
      case PingPacket() || PongPacket():
        break;
    }
  }

  // ─── body decode ────────────────────────────────────────────────

  static PtpIpPacket _decodeBody(PtpIpPacketType type, ByteReader r) {
    switch (type.value) {
      case 0x01:
        final guid = r.readBytes(16);
        final name = r.readUtf16LeNullTerminated();
        final minor = r.readU16();
        final major = r.readU16();
        return InitCommandRequestPacket(
          clientGuid: Uint8List.fromList(guid),
          friendlyName: name,
          protocolVersionMinor: minor,
          protocolVersionMajor: major,
        );
      case 0x02:
        final conn = r.readU32();
        final guid = r.readBytes(16);
        final name = r.readUtf16LeNullTerminated();
        final minor = r.remaining >= 2 ? r.readU16() : 0;
        final major = r.remaining >= 2 ? r.readU16() : 0;
        return InitCommandAckPacket(
          connectionNumber: conn,
          serverGuid: Uint8List.fromList(guid),
          serverName: name,
          protocolVersionMinor: minor,
          protocolVersionMajor: major,
        );
      case 0x03:
        return InitEventRequestPacket(connectionNumber: r.readU32());
      case 0x04:
        return const InitEventAckPacket();
      case 0x05:
        return InitFailPacket(reason: r.readU32());
      case 0x06:
        final dpi = r.readU32();
        final op = r.readU32();
        final tx = r.readU32();
        final params = r.readTrailingUint32Params();
        return CmdRequestPacket(
          dataPhaseInfo: dpi,
          opcode: op,
          transactionId: tx,
          params: params,
        );
      case 0x07:
        final code = r.readU32();
        final tx = r.readU32();
        final params = r.readTrailingUint32Params();
        return CmdResponsePacket(
          responseCode: code,
          transactionId: tx,
          params: params,
        );
      case 0x08:
        final code = r.readU32();
        final tx = r.readU32();
        final params = r.readTrailingUint32Params(max: 3);
        return EventPacket(
          eventCode: code,
          transactionId: tx,
          params: params,
        );
      case 0x09:
        final tx = r.readU32();
        final low = r.readU32();
        final high = r.remaining >= 4 ? r.readU32() : 0;
        final total = (high << 32) | low;
        return StartDataPacket(transactionId: tx, totalDataLength: total);
      case 0x0A:
        final tx = r.readU32();
        return DataPacket(
          transactionId: tx,
          payload: Uint8List.fromList(r.readRemaining()),
        );
      case 0x0B:
        return CancelTransactionPacket(transactionId: r.readU32());
      case 0x0C:
        final tx = r.readU32();
        return EndDataPacket(
          transactionId: tx,
          payload: Uint8List.fromList(r.readRemaining()),
        );
      case 0x0D:
        return const PingPacket();
      case 0x0E:
        return const PongPacket();
      default:
        throw PtpProtocolException(
          'unknown packet type 0x${type.value.toRadixString(16)}',
        );
    }
  }
}
