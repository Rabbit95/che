import 'dart:async';
import 'dart:typed_data';

import '../constants/packet_types.dart';
import '../errors/ptp_errors.dart';
import '../model/ptp_ip_packet.dart';
import 'ptpip_codec.dart';

/// Reassembles PTP-IP packets from an arbitrary byte stream.
///
/// TCP delivers a stream, not messages; a single [Socket] `data` event can
/// contain a partial packet, a full packet, or several packets glued
/// together. This framer buffers bytes, reads the LE `length` prefix, and
/// only emits a decoded [PtpIpPacket] once the full frame is present.
final class PacketFramer {
  PacketFramer();

  // Default copy: true — we do toBytes() then re-feed a sublist view of the
  // same buffer, which is only sound when BytesBuilder owns copies of the
  // input chunks rather than aliasing them.
  final BytesBuilder _buffer = BytesBuilder();
  // Broadcast so both the async caller waiting on Init*Ack and the
  // long-lived transport dispatcher can subscribe without racing.
  final StreamController<PtpIpPacket> _out =
      StreamController<PtpIpPacket>.broadcast();

  Stream<PtpIpPacket> get stream => _out.stream;

  /// Feed raw bytes from a socket or USB read.
  void feed(List<int> chunk) {
    if (_out.isClosed) return;
    _buffer.add(chunk);
    try {
      _drain();
    } on PtpException catch (e, st) {
      _out.addError(e, st);
      // Framing corruption is unrecoverable — drop the rest of the buffer
      // so callers get a single error rather than a cascade.
      _buffer.clear();
    }
  }

  void _drain() {
    while (true) {
      final buf = _buffer.toBytes();
      if (buf.length < PtpIpPacketType.headerBytes) return;

      final view = ByteData.sublistView(buf);
      final length = view.getUint32(0, Endian.little);
      if (length < PtpIpPacketType.headerBytes) {
        throw PtpProtocolException(
          'invalid frame length $length (< header)',
        );
      }
      if (buf.length < length) return;

      final frame = Uint8List.sublistView(buf, 0, length);
      final packet = PtpIpCodec.decode(Uint8List.fromList(frame));

      _buffer
        ..clear()
        ..add(Uint8List.sublistView(buf, length));

      _out.add(packet);
    }
  }

  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}
