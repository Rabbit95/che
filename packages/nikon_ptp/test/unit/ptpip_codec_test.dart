import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('PtpIpCodec', () {
    final guid = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

    test('InitCommandRequest round-trip preserves fields', () {
      const req = InitCommandRequestPacket.new;
      final packet = req(
        clientGuid: guid,
        friendlyName: 'Nikon Z Control',
      );
      final bytes = PtpIpCodec.encode(packet);
      final decoded = PtpIpCodec.decode(bytes) as InitCommandRequestPacket;

      expect(decoded.clientGuid, equals(guid));
      expect(decoded.friendlyName, 'Nikon Z Control');
      expect(decoded.protocolVersionMajor, 0x0001);
      expect(decoded.protocolVersionMinor, 0x0000);
      expect(decoded.type, equals(PtpIpPacketType.initCommandRequest));
    });

    test('InitCommandRequest header length matches encoded buffer', () {
      final bytes = PtpIpCodec.encode(
        InitCommandRequestPacket(
          clientGuid: guid,
          friendlyName: '',
        ),
      );
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(0, Endian.little), bytes.length);
      expect(view.getUint32(4, Endian.little), 0x01); // type
    });

    test('InitCommandRequest encodes version minor before major', () {
      final bytes = PtpIpCodec.encode(
        InitCommandRequestPacket(
          clientGuid: guid,
          friendlyName: '',
        ),
      );
      // 8 header + 16 guid + 2 null terminator = 26; then minor|major.
      final view = ByteData.sublistView(bytes);
      expect(view.getUint16(26, Endian.little), 0x0000); // minor first
      expect(view.getUint16(28, Endian.little), 0x0001); // major second
    });

    test('InitEventRequest is exactly 12 bytes', () {
      final bytes = PtpIpCodec.encode(
        const InitEventRequestPacket(connectionNumber: 0xDEADBEEF),
      );
      expect(bytes.length, 12);
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(0, Endian.little), 12);
      expect(view.getUint32(4, Endian.little), 0x03);
      expect(view.getUint32(8, Endian.little), 0xDEADBEEF);
    });

    test('CmdRequest with 3 params encodes 20 bytes of body', () {
      final bytes = PtpIpCodec.encode(
        const CmdRequestPacket(
          dataPhaseInfo: 1,
          opcode: 0x9435,
          transactionId: 42,
          params: [1, 0, 0],
        ),
      );
      // header 8 + dataPhaseInfo 4 + opcode 4 + tx 4 + 3*4 params = 32
      expect(bytes.length, 32);
      final decoded = PtpIpCodec.decode(bytes) as CmdRequestPacket;
      expect(decoded.opcode, 0x9435);
      expect(decoded.transactionId, 42);
      expect(decoded.params, [1, 0, 0]);
    });

    test('CmdResponse round-trip with variable param count', () {
      for (final count in const [0, 1, 3, 5]) {
        final params = List<int>.generate(count, (i) => 0x1000 + i);
        final bytes = PtpIpCodec.encode(
          CmdResponsePacket(
            responseCode: 0x2001,
            transactionId: 7,
            params: params,
          ),
        );
        final decoded = PtpIpCodec.decode(bytes) as CmdResponsePacket;
        expect(decoded.responseCode, 0x2001);
        expect(decoded.transactionId, 7);
        expect(decoded.params, params);
      }
    });

    test('StartData encodes 64-bit total length as two LE uint32', () {
      // 5 GiB — well past uint32 range, must survive round-trip.
      const total = 0x1_4000_0000;
      final bytes = PtpIpCodec.encode(
        const StartDataPacket(transactionId: 1, totalDataLength: total),
      );
      final decoded = PtpIpCodec.decode(bytes) as StartDataPacket;
      expect(decoded.totalDataLength, total);
    });

    test('Data + EndData preserve payload bytes exactly', () {
      final payload =
          Uint8List.fromList(List<int>.generate(512, (i) => i & 0xFF));
      final startBytes = PtpIpCodec.encode(
        StartDataPacket(transactionId: 9, totalDataLength: payload.length),
      );
      expect(PtpIpCodec.decode(startBytes), isA<StartDataPacket>());

      final dataBytes = PtpIpCodec.encode(
        DataPacket(transactionId: 9, payload: payload),
      );
      final decodedData = PtpIpCodec.decode(dataBytes) as DataPacket;
      expect(decodedData.payload, equals(payload));

      final endBytes = PtpIpCodec.encode(
        EndDataPacket(transactionId: 9, payload: payload),
      );
      final decodedEnd = PtpIpCodec.decode(endBytes) as EndDataPacket;
      expect(decodedEnd.payload, equals(payload));
    });

    test('Event with 3 params round-trip', () {
      final bytes = PtpIpCodec.encode(
        const EventPacket(
          eventCode: 0xC101,
          transactionId: 11,
          params: [0xABCDEF01, 0x2, 0x3],
        ),
      );
      final decoded = PtpIpCodec.decode(bytes) as EventPacket;
      expect(decoded.eventCode, 0xC101);
      expect(decoded.params.first, 0xABCDEF01);
    });

    test('Ping/Pong are exactly 8 bytes', () {
      expect(PtpIpCodec.encode(const PingPacket()).length, 8);
      expect(PtpIpCodec.encode(const PongPacket()).length, 8);
      expect(PtpIpCodec.decode(PtpIpCodec.encode(const PingPacket())),
          isA<PingPacket>());
    });

    test('InitFail preserves reason code', () {
      final bytes = PtpIpCodec.encode(
        const InitFailPacket(reason: 0x2003),
      );
      final decoded = PtpIpCodec.decode(bytes) as InitFailPacket;
      expect(decoded.reason, 0x2003);
    });

    test('decode rejects mismatched length header', () {
      final bytes = Uint8List(12);
      // Header claims 999 bytes but buffer is 12.
      ByteData.sublistView(bytes).setUint32(0, 999, Endian.little);
      ByteData.sublistView(bytes).setUint32(4, 0x03, Endian.little);
      expect(
        () => PtpIpCodec.decode(bytes),
        throwsA(isA<PtpProtocolException>()),
      );
    });

    test('decode rejects unknown packet type', () {
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setUint32(0, 8, Endian.little);
      ByteData.sublistView(bytes).setUint32(4, 0xFF, Endian.little);
      expect(
        () => PtpIpCodec.decode(bytes),
        throwsA(isA<PtpProtocolException>()),
      );
    });
  });
}
