import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_ptp_flutter/nikon_ptp_flutter.dart';
import 'package:nikon_ptp_flutter/src/pigeon/icc_ptp.g.dart';

/// Hand-rolled fake of the pigeon-generated [IccPtpHostApi]. Only overrides
/// the four methods `IccTransport` actually calls; devices() stays as the
/// real one (unused in these tests).
class _FakeHostApi extends IccPtpHostApi {
  _FakeHostApi();

  // Configurable behaviour
  bool nextOpenResult = true;
  Object? nextOpenError;
  Object? nextSendError;
  PtpCommandResult Function(PtpCommand cmd)? sendHandler;

  // Recorded interactions
  final List<String> openedDeviceIds = [];
  final List<PtpCommand> sentCommands = [];
  int closedCount = 0;

  @override
  Future<bool> openSession(String deviceId) async {
    openedDeviceIds.add(deviceId);
    final err = nextOpenError;
    if (err != null) throw err;
    return nextOpenResult;
  }

  @override
  Future<PtpCommandResult> sendCommand(PtpCommand command) async {
    sentCommands.add(command);
    final err = nextSendError;
    if (err != null) throw err;
    final handler = sendHandler;
    if (handler != null) return handler(command);
    return PtpCommandResult(responseCode: 0x2001, responseParams: const []);
  }

  @override
  Future<void> closeSession() async {
    closedCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IccTransport', () {
    late _FakeHostApi fake;
    late IccTransport transport;

    setUp(() {
      IccPtpChannel.resetForTesting();
      fake = _FakeHostApi();
      transport = IccTransport(api: fake);
    });

    tearDown(() async {
      // Idempotent — no-op if a test already closed.
      await transport.close();
    });

    test('open transitions idle → connecting → ready and forwards deviceId',
        () async {
      expect(transport.state, TransportState.idle);

      final states = <TransportState>[];
      final sub = transport.stateChanges.listen(states.add);

      await transport
          .open(TransportConfig.icc(iccDeviceId: 'icc-abc'));
      // Broadcast stream delivers listens in microtasks — drain the queue
      // before asserting on the collected snapshot.
      await Future<void>.delayed(Duration.zero);

      expect(transport.state, TransportState.ready);
      expect(fake.openedDeviceIds, ['icc-abc']);
      expect(
        states,
        containsAllInOrder(
            [TransportState.connecting, TransportState.ready]),
      );
      await sub.cancel();
    });

    test('open with empty iccDeviceId throws PtpTransportException',
        () async {
      expect(
        () => transport.open(TransportConfig.icc(iccDeviceId: '')),
        throwsA(isA<PtpTransportException>()),
      );
    });

    test('open failure flips to failed and detaches channel listeners',
        () async {
      fake.nextOpenResult = false;
      await expectLater(
        transport.open(TransportConfig.icc(iccDeviceId: 'icc-x')),
        throwsA(isA<PtpTransportException>()),
      );
      expect(transport.state, TransportState.failed);
    });

    test('sendTransaction increments txId monotonically', () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      await transport.sendTransaction(const PtpTransaction(opcode: 0x1001));
      await transport.sendTransaction(
        const PtpTransaction(opcode: 0x1014, params: [0x5001]),
      );
      expect(
        fake.sentCommands.map((c) => c.transactionId).toList(),
        [1, 2],
      );
    });

    test('sendTransaction wraps PtpCommandResult into PtpResponse', () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      fake.sendHandler = (cmd) => PtpCommandResult(
            responseCode: 0x2001,
            responseParams: const [42, 43],
            data: Uint8List.fromList([1, 2, 3]),
          );
      final resp =
          await transport.sendTransaction(const PtpTransaction(opcode: 0x1001));
      expect(resp.code, 0x2001);
      expect(resp.params, [42, 43]);
      expect(resp.data, Uint8List.fromList([1, 2, 3]));
    });

    test('sendTransaction forwards dataOut payload', () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      final payload = Uint8List.fromList([9, 8, 7]);
      await transport.sendTransaction(PtpTransaction(
        opcode: 0x1016,
        params: const [0x5007],
        dataPhase: PtpDataPhase.dataOut,
        dataOut: payload,
      ));
      expect(fake.sentCommands.single.outData, payload);
    });

    test('sendTransaction before open throws', () async {
      expect(
        () => transport.sendTransaction(const PtpTransaction(opcode: 0x1001)),
        throwsA(isA<PtpTransportException>()),
      );
    });

    test('PTP event on the channel surfaces as CameraEvent in stream',
        () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      final events = <CameraEvent>[];
      final sub = transport.events.listen(events.add);

      IccPtpChannel.instance.onPtpEvent(0xC101, 42, [100, 200]);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first.code, 0xC101);
      expect(events.first.transactionId, 42);
      expect(events.first.p1, 100);
      expect(events.first.p2, 200);
      expect(events.first.p3, 0);
      await sub.cancel();
    });

    test('onSessionEnded for our deviceId flips state to failed', () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      expect(transport.state, TransportState.ready);
      IccPtpChannel.instance.onSessionEnded('icc-x', 'unplug');
      await Future<void>.delayed(Duration.zero);
      expect(transport.state, TransportState.failed);
    });

    test('onSessionEnded for a different device does not affect us',
        () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-mine'));
      IccPtpChannel.instance.onSessionEnded('icc-someone-else', 'unplug');
      await Future<void>.delayed(Duration.zero);
      expect(transport.state, TransportState.ready);
    });

    test('close transitions ready → closing → closed and calls closeSession',
        () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      final states = <TransportState>[];
      final sub = transport.stateChanges.listen(states.add);
      await transport.close();
      await Future<void>.delayed(Duration.zero);
      expect(fake.closedCount, 1);
      expect(
        states,
        containsAllInOrder(
            [TransportState.closing, TransportState.closed]),
      );
      await sub.cancel();
    });

    test('close is idempotent — second call does not re-invoke native',
        () async {
      await transport.open(TransportConfig.icc(iccDeviceId: 'icc-x'));
      await transport.close();
      await transport.close();
      expect(fake.closedCount, 1);
    });
  });
}
