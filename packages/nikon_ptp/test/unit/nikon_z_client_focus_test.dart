import 'dart:async';
import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

/// Fake transport that records every transaction and lets the test
/// program response codes per opcode. Only implements the surface the
/// tapToFocus / LV happy paths exercise.
class _RecordingTransport implements Transport {
  final List<PtpTransaction> sent = <PtpTransaction>[];
  final Map<int, int> responseCodes = <int, int>{};
  final Map<int, Uint8List?> responseData = <int, Uint8List?>{};

  @override
  TransportChannel get channel => TransportChannel.wifi;

  @override
  TransportState get state => TransportState.ready;

  @override
  Stream<TransportState> get stateChanges =>
      const Stream<TransportState>.empty();

  @override
  Stream<CameraEvent> get events => const Stream<CameraEvent>.empty();

  @override
  Future<void> open(TransportConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    sent.add(transaction);
    final code = responseCodes[transaction.opcode] ?? PtpResponseCode.ok;
    return PtpResponse(
      code: code,
      params: const <int>[],
      data: responseData[transaction.opcode],
    );
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) async* {
    // No LV frame streaming needed in these focus tests.
  }
}

void main() {
  group('NikonZClient.tapToFocus', () {
    late _RecordingTransport transport;
    late PtpSession session;
    late NikonZClient client;

    setUp(() {
      transport = _RecordingTransport();
      session = PtpSession(transport: transport);
      client = NikonZClient(session);
    });

    test('sends ChangeAfArea then AfDrive when drive=true (default)',
        () async {
      await client.tapToFocus(1024, 512);
      expect(transport.sent, hasLength(2));
      expect(transport.sent[0].opcode, NikonOpcode.changeAfArea);
      expect(transport.sent[0].params, [1024, 512]);
      expect(transport.sent[1].opcode, NikonOpcode.afDrive);
    });

    test('skips AfDrive when drive=false', () async {
      await client.tapToFocus(100, 200, drive: false);
      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.opcode, NikonOpcode.changeAfArea);
    });

    test('throws PtpResponseException when ChangeAfArea rejects', () async {
      transport.responseCodes[NikonOpcode.changeAfArea] =
          PtpResponseCode.invalidParameter;
      await expectLater(
        client.tapToFocus(0, 0),
        throwsA(isA<PtpResponseException>()
            .having((e) => e.opcode, 'opcode', NikonOpcode.changeAfArea)),
      );
      // Did NOT proceed to AfDrive after the aim failed.
      expect(transport.sent, hasLength(1));
    });

    test('AF-out-of-focus is not fatal (camera reports it, UI does not care)',
        () async {
      transport.responseCodes[NikonOpcode.afDrive] =
          PtpResponseCode.nikonOutOfFocus;
      // Should NOT throw — a tap on a low-contrast area is normal.
      await client.tapToFocus(500, 500);
      expect(transport.sent, hasLength(2));
    });

    test('other AF driver failures still surface', () async {
      transport.responseCodes[NikonOpcode.afDrive] =
          PtpResponseCode.deviceBusy;
      await expectLater(
        client.tapToFocus(500, 500),
        throwsA(isA<PtpResponseException>()
            .having((e) => e.opcode, 'opcode', NikonOpcode.afDrive)),
      );
    });
  });

  group('NikonZClient.getLiveViewFrameDecoded', () {
    late _RecordingTransport transport;
    late NikonZClient client;

    setUp(() {
      transport = _RecordingTransport();
      client = NikonZClient(PtpSession(transport: transport));
    });

    test('returns decoded LiveViewFrame for a well-formed blob', () async {
      final header = Uint8List(384);
      ByteData.sublistView(header)
        ..setUint16(0x00, 1280, Endian.little)
        ..setUint16(0x02, 720, Endian.little);
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final blob = Uint8List(header.length + jpeg.length)
        ..setRange(0, header.length, header)
        ..setRange(header.length, header.length + jpeg.length, jpeg);
      transport.responseData[NikonOpcode.getLiveViewImageEx] = blob;

      final frame = await client.getLiveViewFrameDecoded();
      expect(frame, isNotNull);
      expect(frame!.header.imageWidth, 1280);
      expect(frame.header.imageHeight, 720);
      expect(frame.jpeg.length, 4);
    });

    test('returns null when camera answers with empty payload', () async {
      transport.responseData[NikonOpcode.getLiveViewImageEx] = Uint8List(0);
      final frame = await client.getLiveViewFrameDecoded();
      expect(frame, isNull);
    });
  });
}
