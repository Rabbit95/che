import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp_flutter/nikon_ptp_flutter.dart';

/// Programmable [WifiDiscoveryHandle] — drives events into
/// [WifiCameraDiscovery] without any real mDNS plumbing. Records lifecycle
/// calls (`ready` / `start` / `stop` / `resolve`) so tests can assert on
/// them.
class _FakeHandle implements WifiDiscoveryHandle {
  _FakeHandle(this.serviceType);

  final String serviceType;
  final StreamController<BonsoirDiscoveryEvent> _events =
      StreamController<BonsoirDiscoveryEvent>.broadcast();

  bool readyCalled = false;
  bool startCalled = false;
  int stopCallCount = 0;
  final List<BonsoirService> resolveCalls = [];

  bool _stopped = false;

  /// If non-null, [ready] throws this the next time it's called.
  Object? nextReadyError;

  /// If non-null, [resolve] throws this each time it's called.
  Object? nextResolveError;

  @override
  Future<void> ready() async {
    readyCalled = true;
    final err = nextReadyError;
    if (err != null) {
      nextReadyError = null;
      throw err;
    }
  }

  @override
  Future<void> start() async {
    startCalled = true;
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
    _stopped = true;
  }

  @override
  bool get isStopped => _stopped;

  @override
  Future<void> resolve(BonsoirService service) async {
    resolveCalls.add(service);
    final err = nextResolveError;
    if (err != null) throw err;
  }

  @override
  Stream<BonsoirDiscoveryEvent>? get eventStream => _events.stream;

  void push(BonsoirDiscoveryEvent event) => _events.add(event);
  void pushError(Object error) => _events.addError(error);
  Future<void> dispose() => _events.close();
}

BonsoirDiscoveryEvent _found(String name, String type) => BonsoirDiscoveryEvent(
      type: BonsoirDiscoveryEventType.discoveryServiceFound,
      service: BonsoirService.ignoreNorms(name: name, type: type, port: 15740),
    );

BonsoirDiscoveryEvent _resolved(
  String name,
  String type,
  String host, {
  int port = 15740,
  Map<String, String> attributes = const {},
}) =>
    BonsoirDiscoveryEvent(
      type: BonsoirDiscoveryEventType.discoveryServiceResolved,
      service: ResolvedBonsoirService(
        name: name,
        type: type,
        port: port,
        host: host,
        attributes: attributes,
      ),
    );

BonsoirDiscoveryEvent _lost(String name, String type) => BonsoirDiscoveryEvent(
      type: BonsoirDiscoveryEventType.discoveryServiceLost,
      service: BonsoirService.ignoreNorms(name: name, type: type, port: 15740),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WifiCameraDescriptor', () {
    test('id is stable and prefixed with wifi-', () {
      const d = WifiCameraDescriptor(
        name: 'NIKON Z6III',
        host: '192.168.1.1',
        port: 15740,
      );
      expect(d.id, 'wifi-NIKON Z6III');
    });

    test('equality compares name, host, port', () {
      const a = WifiCameraDescriptor(
        name: 'Z8',
        host: '10.0.0.1',
        port: 15740,
      );
      const b = WifiCameraDescriptor(
        name: 'Z8',
        host: '10.0.0.1',
        port: 15740,
      );
      const c = WifiCameraDescriptor(
        name: 'Z8',
        host: '10.0.0.2',
        port: 15740,
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('WifiCameraDiscovery', () {
    late _FakeHandle handle;
    late WifiCameraDiscovery discovery;

    setUp(() {
      handle = _FakeHandle('_ptp._tcp');
      discovery = WifiCameraDiscovery(
        serviceTypes: const ['_ptp._tcp'],
        discoveryFactory: (_) => handle,
      );
    });

    tearDown(() async {
      await handle.dispose();
    });

    test('watch() emits an initial empty snapshot before any events', () async {
      final firstEmit = discovery.watch().first;
      final snap = await firstEmit;
      expect(snap, isEmpty);
    });

    test('subscribing calls ready() and start() on the handle', () async {
      final sub = discovery.watch().listen((_) {});
      // Let onListen fire.
      await Future<void>.delayed(Duration.zero);
      expect(handle.readyCalled, isTrue);
      expect(handle.startCalled, isTrue);
      await sub.cancel();
    });

    test('serviceFound triggers a resolve on the handle', () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      handle.push(_found('NIKON Z6III', '_ptp._tcp'));
      await Future<void>.delayed(Duration.zero);

      expect(handle.resolveCalls, hasLength(1));
      expect(handle.resolveCalls.single.name, 'NIKON Z6III');
      // Found alone doesn't produce an entry — only resolve does.
      expect(snapshots.last, isEmpty);
      await sub.cancel();
    });

    test('serviceResolved adds a descriptor with host + port', () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      handle.push(
          _resolved('NIKON Z6III', '_ptp._tcp', '192.168.1.1', port: 15740));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.last, hasLength(1));
      final cam = snapshots.last.single;
      expect(cam.name, 'NIKON Z6III');
      expect(cam.host, '192.168.1.1');
      expect(cam.port, 15740);
      await sub.cancel();
    });

    test('serviceResolved without host is silently dropped', () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      handle.push(BonsoirDiscoveryEvent(
        type: BonsoirDiscoveryEventType.discoveryServiceResolved,
        service: ResolvedBonsoirService(
          name: 'NIKON Z8',
          type: '_ptp._tcp',
          port: 15740,
          host: null,
        ),
      ));
      await Future<void>.delayed(Duration.zero);

      // Only the initial empty snapshot — the null-host resolve doesn't
      // trigger a new emit.
      expect(snapshots, hasLength(1));
      expect(snapshots.single, isEmpty);
      await sub.cancel();
    });

    test('serviceLost removes an already-resolved descriptor', () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      handle.push(_resolved('NIKON Z6III', '_ptp._tcp', '192.168.1.1'));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last, hasLength(1));

      handle.push(_lost('NIKON Z6III', '_ptp._tcp'));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.last, isEmpty);
      await sub.cancel();
    });

    test('serviceLost for an unknown name does not emit a spurious snapshot',
        () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      final before = snapshots.length;
      handle.push(_lost('never-seen', '_ptp._tcp'));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.length, before);
      await sub.cancel();
    });

    test('duplicate resolves for the same name update in place', () async {
      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      handle.push(_resolved('NIKON Z6III', '_ptp._tcp', '192.168.1.1'));
      await Future<void>.delayed(Duration.zero);
      handle.push(_resolved('NIKON Z6III', '_ptp._tcp', '192.168.1.42'));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.last, hasLength(1));
      expect(snapshots.last.single.host, '192.168.1.42');
      await sub.cancel();
    });

    test('cancelling the subscription stops the handle', () async {
      final sub = discovery.watch().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(handle.stopCallCount, 0);

      await sub.cancel();
      // Give onCancel time to run.
      await Future<void>.delayed(Duration.zero);

      expect(handle.stopCallCount, 1);
    });

    test('resolve failures do not crash the stream', () async {
      handle.nextResolveError = StateError('boom');
      final snapshots = <List<WifiCameraDescriptor>>[];
      final errors = <Object>[];
      final sub = discovery.watch().listen(
            snapshots.add,
            onError: errors.add,
          );
      await Future<void>.delayed(Duration.zero);

      handle.push(_found('NIKON Z6III', '_ptp._tcp'));
      await Future<void>.delayed(Duration.zero);

      // The resolve throws, but we .catchError it — no stream error.
      expect(errors, isEmpty);
      expect(snapshots.last, isEmpty);
      await sub.cancel();
    });

    test('event-stream errors are surfaced to the caller', () async {
      final errors = <Object>[];
      final sub = discovery.watch().listen(
            (_) {},
            onError: errors.add,
          );
      await Future<void>.delayed(Duration.zero);

      handle.pushError(StateError('platform dropped'));
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
      await sub.cancel();
    });

    test('ready failure on one service type still fires empty snapshot',
        () async {
      handle.nextReadyError = StateError('platform not available');
      final snapshots = <List<WifiCameraDescriptor>>[];
      final errors = <Object>[];
      final sub = discovery.watch().listen(
            snapshots.add,
            onError: errors.add,
          );
      await Future<void>.delayed(Duration.zero);

      // Initial empty snapshot delivered first.
      expect(snapshots, isNotEmpty);
      expect(snapshots.first, isEmpty);
      // The ready() failure surfaces as a stream error but doesn't close
      // the stream.
      expect(errors, isNotEmpty);
      await sub.cancel();
    });
  });

  group('WifiCameraDiscovery with multiple service types', () {
    test('starts a handle per type and merges resolved snapshots', () async {
      final handles = <String, _FakeHandle>{};
      final discovery = WifiCameraDiscovery(
        serviceTypes: const ['_ptp._tcp', '_nikon._tcp'],
        discoveryFactory: (type) {
          final h = _FakeHandle(type);
          handles[type] = h;
          return h;
        },
      );
      addTearDown(() async {
        for (final h in handles.values) {
          await h.dispose();
        }
      });

      final snapshots = <List<WifiCameraDescriptor>>[];
      final sub = discovery.watch().listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      expect(handles.keys, containsAll(['_ptp._tcp', '_nikon._tcp']));

      handles['_ptp._tcp']!
          .push(_resolved('NIKON Z6III', '_ptp._tcp', '192.168.1.1'));
      await Future<void>.delayed(Duration.zero);
      handles['_nikon._tcp']!
          .push(_resolved('NIKON Z8', '_nikon._tcp', '192.168.1.2'));
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.last.map((c) => c.name),
          containsAll(['NIKON Z6III', 'NIKON Z8']));

      await sub.cancel();
    });
  });
}
