import 'dart:async';
import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('PacketFramer', () {
    late PacketFramer framer;
    late List<Object> received;
    late Completer<void> receivedFirst;
    late StreamSubscription<dynamic> sub;

    setUp(() {
      framer = PacketFramer();
      received = [];
      receivedFirst = Completer<void>();
      sub = framer.stream.listen(
        (pkt) {
          received.add(pkt);
          if (!receivedFirst.isCompleted) receivedFirst.complete();
        },
        onError: received.add,
      );
    });

    tearDown(() async {
      await sub.cancel();
      await framer.close();
    });

    test('single complete packet emits one frame', () async {
      final bytes = PtpIpCodec.encode(const PingPacket());
      framer.feed(bytes);
      await pumpEventQueue();
      expect(received, hasLength(1));
      expect(received.single, isA<PingPacket>());
    });

    test('two packets in one chunk both emit', () async {
      final a = PtpIpCodec.encode(const PingPacket());
      final b = PtpIpCodec.encode(
        const CmdResponsePacket(
          responseCode: 0x2001,
          transactionId: 1,
          params: [],
        ),
      );
      framer.feed([...a, ...b]);
      await pumpEventQueue();
      expect(received, hasLength(2));
      expect(received[0], isA<PingPacket>());
      expect(received[1], isA<CmdResponsePacket>());
    });

    test('packet split across multiple feed calls emits once, correctly',
        () async {
      final packet = CmdResponsePacket(
        responseCode: 0x2001,
        transactionId: 42,
        params: List<int>.filled(5, 0xDEADBEEF),
      );
      final bytes = PtpIpCodec.encode(packet);
      for (var i = 0; i < bytes.length; i++) {
        framer.feed(<int>[bytes[i]]);
      }
      await pumpEventQueue();
      expect(received, hasLength(1));
      final decoded = received.single as CmdResponsePacket;
      expect(decoded.transactionId, 42);
      expect(decoded.params, everyElement(0xDEADBEEF));
    });

    test('framer surfaces PtpProtocolException on garbage length', () async {
      // length header = 0 (< 8), guaranteed to be rejected on drain.
      framer.feed(Uint8List.fromList(<int>[0, 0, 0, 0, 0, 0, 0, 0]));
      await pumpEventQueue();
      expect(received, isNotEmpty);
      expect(received.last, isA<PtpProtocolException>());
    });
  });
}
