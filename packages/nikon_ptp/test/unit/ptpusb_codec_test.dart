import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('PtpUsbCodec.encodeCommand', () {
    test('empty params produces exactly 12-byte header', () {
      final bytes = PtpUsbCodec.encodeCommand(
        opcode: 0x1001, // GetDeviceInfo
        transactionId: 0,
      );
      expect(bytes.length, 12);
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(0, Endian.little), 12);
      expect(view.getUint16(4, Endian.little), 0x0001); // command
      expect(view.getUint16(6, Endian.little), 0x1001);
      expect(view.getUint32(8, Endian.little), 0);
    });

    test('5 params → header + 20 payload bytes = 32 total', () {
      final bytes = PtpUsbCodec.encodeCommand(
        opcode: 0x9431,
        transactionId: 42,
        params: [1, 2, 3, 4, 5],
      );
      expect(bytes.length, 32);
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(0, Endian.little), 32);
      expect(view.getUint32(8, Endian.little), 42);
      for (var i = 0; i < 5; i++) {
        expect(view.getUint32(12 + i * 4, Endian.little), i + 1);
      }
    });

    test('OpenSession(1) matches spec-encoded wire bytes', () {
      // Golden vector — every PTP-USB client emits the same 16 bytes
      // for OpenSession with sessionId=1, txId=0.
      final bytes = PtpUsbCodec.encodeCommand(
        opcode: 0x1002,
        transactionId: 0,
        params: [1],
      );
      expect(
        bytes,
        equals(<int>[
          // container length = 16
          0x10, 0x00, 0x00, 0x00,
          // type = 1 (command)
          0x01, 0x00,
          // opcode = 0x1002
          0x02, 0x10,
          // txId = 0
          0x00, 0x00, 0x00, 0x00,
          // param0 = 1
          0x01, 0x00, 0x00, 0x00,
        ]),
      );
    });
  });

  group('PtpUsbCodec.encodeDataHeader / encodeData', () {
    test('data header carries the ORIGINAL opcode, not a data-specific code',
        () {
      final header = PtpUsbCodec.encodeDataHeader(
        opcode: 0x1016, // SetDevicePropValue
        transactionId: 5,
        totalDataLength: 4,
      );
      final view = ByteData.sublistView(header);
      expect(view.getUint16(4, Endian.little), 0x0002); // data
      expect(view.getUint16(6, Endian.little), 0x1016); // same as opcode
      expect(view.getUint32(0, Endian.little), 12 + 4);
    });

    test('encodeData inlines payload after 12-byte header', () {
      final data = PtpUsbCodec.encodeData(
        opcode: 0x1016,
        transactionId: 5,
        payload: Uint8List.fromList([0x2A, 0, 0, 0]),
      );
      expect(data.length, 16);
      expect(data.sublist(12), equals(<int>[0x2A, 0, 0, 0]));
    });

    test('large payload reports correct header length', () {
      final big = Uint8List(64 * 1024);
      final header = PtpUsbCodec.encodeDataHeader(
        opcode: 0x9431,
        transactionId: 99,
        totalDataLength: big.length,
      );
      expect(
        ByteData.sublistView(header).getUint32(0, Endian.little),
        12 + 64 * 1024,
      );
    });
  });

  group('PtpUsbCodec.decode', () {
    test('response round-trip with 3 params', () {
      final encoded = PtpUsbCodec.encodeResponse(
        responseCode: 0x2001,
        transactionId: 7,
        params: [0xDEADBEEF, 0xCAFEBABE, 0x12345678],
      );
      final decoded = PtpUsbCodec.decode(encoded);
      expect(decoded.type, PtpUsbContainerType.response);
      expect(decoded.code, 0x2001);
      expect(decoded.transactionId, 7);
      final params = PtpUsbCodec.decodeParams(decoded.payload);
      expect(params, [0xDEADBEEF, 0xCAFEBABE, 0x12345678]);
    });

    test('command round-trip with 0 params', () {
      final encoded = PtpUsbCodec.encodeCommand(
        opcode: 0x1003, // CloseSession
        transactionId: 88,
      );
      final decoded = PtpUsbCodec.decode(encoded);
      expect(decoded.type, PtpUsbContainerType.command);
      expect(decoded.code, 0x1003);
      expect(decoded.transactionId, 88);
      expect(decoded.payload, isEmpty);
    });

    test('event caps params at 3', () {
      // Simulate a malformed camera that sends 5 params in an event.
      final w = ByteData(12 + 5 * 4);
      w.setUint32(0, 12 + 5 * 4, Endian.little);
      w.setUint16(4, PtpUsbContainerType.event.value, Endian.little);
      w.setUint16(6, 0xC101, Endian.little);
      w.setUint32(8, 3, Endian.little);
      for (var i = 0; i < 5; i++) {
        w.setUint32(12 + i * 4, 0xAA00 + i, Endian.little);
      }
      final decoded = PtpUsbCodec.decode(w.buffer.asUint8List());
      expect(decoded.type, PtpUsbContainerType.event);
      final params = PtpUsbCodec.decodeParams(decoded.payload, max: 3);
      expect(params.length, 3);
      expect(params, [0xAA00, 0xAA01, 0xAA02]);
    });

    test('rejects unknown container type', () {
      final w = ByteData(12);
      w.setUint32(0, 12, Endian.little);
      w.setUint16(4, 0x00FF, Endian.little); // bogus
      expect(
        () => PtpUsbCodec.decode(w.buffer.asUint8List()),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('rejects short buffer', () {
      expect(
        () => PtpUsbCodec.decode(Uint8List(6)),
        throwsA(isA<PtpProtocolException>()),
      );
    });
  });

  group('PtpUsbCodec.peekHeader', () {
    test('extracts length before payload is fully buffered', () {
      // Simulate the first 12 bytes of a 4MB data container.
      final head = Uint8List(12);
      final view = ByteData.sublistView(head);
      view.setUint32(0, 12 + 4 * 1024 * 1024, Endian.little);
      view.setUint16(4, PtpUsbContainerType.data.value, Endian.little);
      view.setUint16(6, 0x1009, Endian.little); // GetObject
      view.setUint32(8, 5, Endian.little);
      final h = PtpUsbCodec.peekHeader(head);
      expect(h.type, PtpUsbContainerType.data);
      expect(h.code, 0x1009);
      expect(h.transactionId, 5);
      expect(h.payloadBytes, 4 * 1024 * 1024);
    });
  });
}
