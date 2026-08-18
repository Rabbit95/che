import 'dart:typed_data';

import '../errors/ptp_errors.dart';
import 'byte_reader.dart';
import 'byte_writer.dart';

/// PTP-USB container types (USB Still Image Class 1.0 §3.1).
///
/// Every bulk transfer on the wire begins with a 12-byte container header
/// followed by a type-specific payload. Distinct from PTP-IP framing.
enum PtpUsbContainerType {
  command(0x0001),
  data(0x0002),
  response(0x0003),
  event(0x0004);

  const PtpUsbContainerType(this.value);
  final int value;

  static PtpUsbContainerType? fromValue(int v) {
    for (final t in values) {
      if (t.value == v) return t;
    }
    return null;
  }
}

/// One PTP-USB container, header + payload.
///
/// [payload] is either 0..5 uint32 params (for command/response), 0..3
/// uint32 params (for event), or raw data bytes (for data).
final class PtpUsbContainer {
  const PtpUsbContainer({
    required this.type,
    required this.code,
    required this.transactionId,
    required this.payload,
  });

  final PtpUsbContainerType type;

  /// - Command: PTP opcode
  /// - Response: PTP response code
  /// - Event: PTP event code
  /// - Data: MUST equal the opcode of the transaction the data belongs to
  final int code;

  final int transactionId;
  final Uint8List payload;
}

/// Encode / decode PTP-USB containers.
///
/// Data phase can be arbitrarily large; the header carries the *total* data
/// length so the receiver knows how many bulk reads to accumulate.
abstract final class PtpUsbCodec {
  PtpUsbCodec._();

  /// Bytes of the mandatory container header.
  static const int headerBytes = 12;

  /// Encode an OperationRequest (Command) block.
  static Uint8List encodeCommand({
    required int opcode,
    required int transactionId,
    List<int> params = const <int>[],
  }) {
    final w = ByteWriter()
      ..writeU32(headerBytes + params.length * 4)
      ..writeU16(PtpUsbContainerType.command.value)
      ..writeU16(opcode)
      ..writeU32(transactionId);
    for (final p in params) {
      w.writeU32(p);
    }
    return w.takeBytes();
  }

  /// Encode a Data-phase header. On the wire the header may be sent alone
  /// (with the payload following in subsequent bulk transfers) or combined
  /// with the payload in a single write — the [totalDataLength] field lets
  /// the receiver know either way.
  static Uint8List encodeDataHeader({
    required int opcode,
    required int transactionId,
    required int totalDataLength,
  }) {
    final w = ByteWriter()
      ..writeU32(headerBytes + totalDataLength)
      ..writeU16(PtpUsbContainerType.data.value)
      ..writeU16(opcode)
      ..writeU32(transactionId);
    return w.takeBytes();
  }

  /// Convenience: encode a Data-phase container with the payload inline.
  static Uint8List encodeData({
    required int opcode,
    required int transactionId,
    required Uint8List payload,
  }) {
    final w = ByteWriter()
      ..writeU32(headerBytes + payload.length)
      ..writeU16(PtpUsbContainerType.data.value)
      ..writeU16(opcode)
      ..writeU32(transactionId)
      ..writeBytes(payload);
    return w.takeBytes();
  }

  /// Encode a Response block. Used only by tests and mock transports —
  /// production code decodes responses coming from the camera.
  static Uint8List encodeResponse({
    required int responseCode,
    required int transactionId,
    List<int> params = const <int>[],
  }) {
    final w = ByteWriter()
      ..writeU32(headerBytes + params.length * 4)
      ..writeU16(PtpUsbContainerType.response.value)
      ..writeU16(responseCode)
      ..writeU32(transactionId);
    for (final p in params) {
      w.writeU32(p);
    }
    return w.takeBytes();
  }

  /// Encode an Event block (async, delivered on the interrupt endpoint).
  static Uint8List encodeEvent({
    required int eventCode,
    required int transactionId,
    List<int> params = const <int>[],
  }) {
    final w = ByteWriter()
      ..writeU32(headerBytes + params.length * 4)
      ..writeU16(PtpUsbContainerType.event.value)
      ..writeU16(eventCode)
      ..writeU32(transactionId);
    for (final p in params) {
      w.writeU32(p);
    }
    return w.takeBytes();
  }

  /// Peek at the header of a container without consuming the payload.
  /// Used by the transport's frame reassembler.
  static PtpUsbHeader peekHeader(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw PtpProtocolException(
        'container too short: ${bytes.length}B < 12B header',
      );
    }
    final view = ByteData.sublistView(bytes);
    return PtpUsbHeader(
      length: view.getUint32(0, Endian.little),
      typeValue: view.getUint16(4, Endian.little),
      code: view.getUint16(6, Endian.little),
      transactionId: view.getUint32(8, Endian.little),
    );
  }

  /// Fully decode a container from a buffer that must contain at least the
  /// number of bytes reported in the header. Extra bytes are ignored — the
  /// framer is expected to size the buffer exactly.
  static PtpUsbContainer decode(Uint8List bytes) {
    final header = peekHeader(bytes);
    final type = PtpUsbContainerType.fromValue(header.typeValue);
    if (type == null) {
      throw PtpProtocolException(
        'unknown container type 0x${header.typeValue.toRadixString(16)}',
      );
    }
    if (bytes.length < header.length) {
      throw PtpProtocolException(
        'container underrun: header says ${header.length}, buffer is ${bytes.length}',
      );
    }
    final r = ByteReader(bytes)
      ..readU32() // length
      ..readU16() // type
      ..readU16() // code
      ..readU32(); // txId
    final payload = r.readBytes(header.length - headerBytes);
    return PtpUsbContainer(
      type: type,
      code: header.code,
      transactionId: header.transactionId,
      payload: Uint8List.fromList(payload),
    );
  }

  /// Split a params-carrying payload (command/response/event) into a list
  /// of LE uint32 values. [max] caps the count so a malformed camera can't
  /// force us to read past the spec-mandated maximum (5 for cmd/resp, 3 for event).
  static List<int> decodeParams(Uint8List payload, {int max = 5}) {
    final count = (payload.length ~/ 4).clamp(0, max);
    if (count == 0) return const <int>[];
    final view = ByteData.sublistView(payload);
    return List<int>.generate(
      count,
      (i) => view.getUint32(i * 4, Endian.little),
    );
  }
}

/// Bare container header — enough to size the follow-up bulk reads.
final class PtpUsbHeader {
  const PtpUsbHeader({
    required this.length,
    required this.typeValue,
    required this.code,
    required this.transactionId,
  });

  final int length;
  final int typeValue;
  final int code;
  final int transactionId;

  PtpUsbContainerType? get type => PtpUsbContainerType.fromValue(typeValue);
  int get payloadBytes => length - PtpUsbCodec.headerBytes;
}
