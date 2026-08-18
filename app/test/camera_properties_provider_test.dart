import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_z_control/shared/providers/camera_properties_provider.dart';

/// Fake [PropertyReader] that lets a test seed prop descriptors,
/// mutate them mid-stream, and push camera events on demand.
class _FakeReader implements PropertyReader {
  final Map<int, DevicePropDesc> _byCode = {};
  final StreamController<CameraEvent> _events = StreamController.broadcast();
  int getCallCount = 0;

  void seed(int propCode, Object currentValue, {int dataType = 0x0004}) {
    _byCode[propCode] = DevicePropDesc(
      propCode: propCode,
      dataType: dataType,
      getSet: 0x01,
      factoryDefault: currentValue,
      currentValue: currentValue,
      form: const NoForm(),
    );
  }

  void updateValue(int propCode, Object newValue) {
    final existing = _byCode[propCode]!;
    _byCode[propCode] = DevicePropDesc(
      propCode: propCode,
      dataType: existing.dataType,
      getSet: existing.getSet,
      factoryDefault: existing.factoryDefault,
      currentValue: newValue,
      form: existing.form,
    );
  }

  void firePropChanged(int propCode) {
    _events.add(
      CameraEvent(
        code: StandardEventCode.devicePropChanged,
        p1: propCode,
      ),
    );
  }

  Future<void> dispose() => _events.close();

  @override
  Stream<CameraEvent> get events => _events.stream;

  @override
  Future<DevicePropDesc> getPropertyDesc(int propCode) async {
    getCallCount++;
    final desc = _byCode[propCode];
    if (desc == null) {
      throw const PtpResponseException(
        PtpResponseCode.devicePropNotSupported,
        opcode: StandardOpcode.getDevicePropDesc,
      );
    }
    return desc;
  }
}

void main() {
  group('watchCameraProperties', () {
    test('emits empty snapshot when no supported core props', () async {
      final reader = _FakeReader();
      final stream = watchCameraProperties(reader, <int>{0x9999});
      final snap = await stream.first;
      expect(snap.byCode, isEmpty);
      await reader.dispose();
    });

    test('initial read populates snapshot with formatted values',
        () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 3200)
        ..seed(StandardPropCode.fNumber, 280)
        ..seed(StandardPropCode.exposureTime, 40);

      final stream = watchCameraProperties(
        reader,
        {
          StandardPropCode.exposureIndex,
          StandardPropCode.fNumber,
          StandardPropCode.exposureTime,
        },
        pollInterval: const Duration(seconds: 30),
      );

      // Third emit = after the third prop read completes.
      final snap = await stream.skip(2).first;
      expect(snap[StandardPropCode.exposureIndex]?.formattedValue, '3200');
      expect(snap[StandardPropCode.fNumber]?.formattedValue, 'f/2.8');
      expect(snap[StandardPropCode.exposureTime]?.formattedValue, '1/250');
      await reader.dispose();
    });

    test('devicePropChanged event triggers targeted refresh', () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 100)
        ..seed(StandardPropCode.fNumber, 400);

      final stream = watchCameraProperties(
        reader,
        {StandardPropCode.exposureIndex, StandardPropCode.fNumber},
        pollInterval: const Duration(seconds: 30),
      );

      final events = <CameraPropertySnapshot>[];
      final sub = stream.listen(events.add);

      // Let the initial full read + emissions settle.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final callsAfterInit = reader.getCallCount;
      expect(callsAfterInit, 2, reason: '2 props on first pass');

      // Camera dial spins — value changes to ISO 6400, event fires.
      reader.updateValue(StandardPropCode.exposureIndex, 6400);
      reader.firePropChanged(StandardPropCode.exposureIndex);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Only one extra read — for ISO, not aperture.
      expect(reader.getCallCount, callsAfterInit + 1);
      expect(
        events.last[StandardPropCode.exposureIndex]?.formattedValue,
        '6400',
      );
      expect(
        events.last[StandardPropCode.fNumber]?.formattedValue,
        'f/4',
      );

      await sub.cancel();
      await reader.dispose();
    });

    test('devicePropChanged with p1=0 refreshes all core props', () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 100)
        ..seed(StandardPropCode.fNumber, 400);

      final stream = watchCameraProperties(
        reader,
        {StandardPropCode.exposureIndex, StandardPropCode.fNumber},
        pollInterval: const Duration(seconds: 30),
      );

      final sub = stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final callsAfterInit = reader.getCallCount;
      expect(callsAfterInit, 2);

      reader.firePropChanged(0); // "everything changed"
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(reader.getCallCount, callsAfterInit + 2);
      await sub.cancel();
      await reader.dispose();
    });

    test('polling timer refreshes on interval', () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 100);

      final stream = watchCameraProperties(
        reader,
        {StandardPropCode.exposureIndex},
        pollInterval: const Duration(milliseconds: 40),
      );

      final sub = stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reader.getCallCount, 1, reason: 'initial full read');

      // Wait through two poll ticks.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reader.getCallCount, greaterThanOrEqualTo(3));

      await sub.cancel();
      await reader.dispose();
    });

    test('unsupported prop is skipped, not fatal', () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 100);
      // fNumber is in supportedPropCodes but reader will throw
      // devicePropNotSupported when asked — should not crash the stream.

      final stream = watchCameraProperties(
        reader,
        {StandardPropCode.exposureIndex, StandardPropCode.fNumber},
        pollInterval: const Duration(seconds: 30),
      );

      final events = <CameraPropertySnapshot>[];
      final sub = stream.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Only ISO was read successfully.
      expect(events.last[StandardPropCode.exposureIndex], isNotNull);
      expect(events.last[StandardPropCode.fNumber], isNull);
      await sub.cancel();
      await reader.dispose();
    });

    test('cancelling the subscription stops the polling timer', () async {
      final reader = _FakeReader()
        ..seed(StandardPropCode.exposureIndex, 100);
      final stream = watchCameraProperties(
        reader,
        {StandardPropCode.exposureIndex},
        pollInterval: const Duration(milliseconds: 20),
      );

      final sub = stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final callsWhileListening = reader.getCallCount;
      expect(callsWhileListening, greaterThan(1));

      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        reader.getCallCount,
        callsWhileListening,
        reason: 'no more polls after cancel',
      );
      await reader.dispose();
    });
  });

  group('CameraPropertySnapshot', () {
    test('empty snapshot lookups return null', () {
      const snap = CameraPropertySnapshot.empty;
      expect(snap[StandardPropCode.exposureIndex], isNull);
      expect(snap.byCode, isEmpty);
    });

    test('lookup by prop code returns matching view', () {
      const desc = DevicePropDesc(
        propCode: StandardPropCode.exposureIndex,
        dataType: 0x0004,
        getSet: 0x01,
        factoryDefault: 100,
        currentValue: 3200,
        form: NoForm(),
      );
      const view = CameraPropertyView(
        propCode: StandardPropCode.exposureIndex,
        desc: desc,
        formattedValue: '3200',
        label: 'ISO',
        longName: 'ISO',
      );
      const snap = CameraPropertySnapshot(<int, CameraPropertyView>{
        StandardPropCode.exposureIndex: view,
      });
      expect(snap[StandardPropCode.exposureIndex], same(view));
      expect(snap[StandardPropCode.fNumber], isNull);
    });
  });
}
