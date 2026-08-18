import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_z_control/shared/providers/camera_control_provider.dart';

/// Records every command dispatched through it, and can be armed to throw
/// on the next call — one target per test, no shared state.
class _FakeTarget implements CameraCommandTarget {
  final List<String> calls = <String>[];
  Object? nextError;

  Future<T> _run<T>(String name, T Function() body) async {
    calls.add(name);
    final err = nextError;
    if (err != null) {
      nextError = null;
      throw err;
    }
    return body();
  }

  @override
  Future<void> capture() => _run('capture', () {});

  @override
  Future<void> startMovieRecording() =>
      _run('startMovieRecording', () {});

  @override
  Future<void> stopMovieRecording() =>
      _run('stopMovieRecording', () {});

  @override
  Future<void> setProperty(int propCode, int dataType, Object value) =>
      _run(
        'setProperty($propCode,$dataType,$value)',
        () {},
      );
}

void main() {
  group('CameraCommands.capture', () {
    test('dispatches to the target', () async {
      final target = _FakeTarget();
      final cmds = CameraCommands(target);

      await cmds.capture();

      expect(target.calls, ['capture']);
    });

    test('wraps a PtpResponseException into a CameraControlFailure with hint',
        () async {
      final target = _FakeTarget()
        ..nextError = const PtpResponseException(
          PtpResponseCode.nikonOutOfFocus,
          opcode: 0x9207,
        );
      final cmds = CameraCommands(target);

      final failure = await _captureThrow<CameraControlFailure>(cmds.capture);

      expect(failure.action, '拍照失败');
      expect(failure.code, PtpResponseCode.nikonOutOfFocus);
      expect(failure.opcode, 0x9207);
      expect(failure.summary, 'Nikon.OutOfFocus');
      expect(failure.hint, contains('对焦失败'));
      expect(failure.userMessage, contains('拍照失败'));
      expect(failure.userMessage, contains('Nikon.OutOfFocus'));
      expect(failure.userMessage, contains('对焦失败'));
    });

    test('wraps a non-PTP error without a hint', () async {
      final target = _FakeTarget()..nextError = StateError('socket dead');
      final cmds = CameraCommands(target);

      final failure = await _captureThrow<CameraControlFailure>(cmds.capture);

      expect(failure.action, '拍照失败');
      expect(failure.hint, isNull);
      expect(failure.userMessage, contains('socket dead'));
    });
  });

  group('CameraCommands movie recording', () {
    test('start dispatches and reports failure with the right action label',
        () async {
      final target = _FakeTarget()
        ..nextError = const PtpResponseException(
          PtpResponseCode.deviceBusy,
          opcode: 0x920A,
        );
      final cmds = CameraCommands(target);

      final failure = await _captureThrow<CameraControlFailure>(
        cmds.startMovieRecording,
      );
      expect(failure.action, '开始录像失败');
      expect(failure.hint, contains('相机正忙'));
    });

    test('stop dispatches and reports failure with the right action label',
        () async {
      final target = _FakeTarget()
        ..nextError = const PtpResponseException(
          PtpResponseCode.accessDenied,
          opcode: 0x920B,
        );
      final cmds = CameraCommands(target);

      final failure = await _captureThrow<CameraControlFailure>(
        cmds.stopMovieRecording,
      );
      expect(failure.action, '停止录像失败');
      expect(failure.hint, contains('USB 模式不对'));
    });

    test('happy-path start+stop dispatches both to the target', () async {
      final target = _FakeTarget();
      final cmds = CameraCommands(target);
      await cmds.startMovieRecording();
      await cmds.stopMovieRecording();
      expect(target.calls, ['startMovieRecording', 'stopMovieRecording']);
    });
  });

  group('CameraCommands.setProperty', () {
    test('passes propCode + dataType + value through to the target', () async {
      final target = _FakeTarget();
      final cmds = CameraCommands(target);
      await cmds.setProperty(StandardPropCode.exposureIndex, 0x0004, 3200);
      expect(target.calls, ['setProperty(20495,4,3200)']);
    });

    test('failure defaults to "写入参数失败" when no actionLabel is given',
        () async {
      final target = _FakeTarget()
        ..nextError = const PtpResponseException(
          PtpResponseCode.invalidDevicePropValue,
          opcode: 0x1016,
        );
      final cmds = CameraCommands(target);
      final failure = await _captureThrow<CameraControlFailure>(
        () => cmds.setProperty(StandardPropCode.fNumber, 0x0004, 280),
      );
      expect(failure.action, '写入参数失败');
      expect(failure.hint, contains('该档位相机拒绝'));
    });

    test('actionLabel overrides the default', () async {
      final target = _FakeTarget()
        ..nextError = const PtpResponseException(
          PtpResponseCode.deviceBusy,
        );
      final cmds = CameraCommands(target);
      final failure = await _captureThrow<CameraControlFailure>(
        () => cmds.setProperty(
          StandardPropCode.exposureIndex,
          0x0004,
          6400,
          actionLabel: '写入 ISO 失败',
        ),
      );
      expect(failure.action, '写入 ISO 失败');
    });
  });

  group('debugHintForResponse', () {
    test('returns null for unmapped codes', () {
      expect(debugHintForResponse(0x2001), isNull);
      expect(debugHintForResponse(0x1234), isNull);
    });

    test('returns a hint for every mapped code', () {
      const mapped = <int>[
        PtpResponseCode.accessDenied,
        PtpResponseCode.sessionAlreadyOpen,
        PtpResponseCode.sessionNotOpen,
        PtpResponseCode.deviceBusy,
        PtpResponseCode.operationNotSupported,
        PtpResponseCode.storeNotAvailable,
        PtpResponseCode.storeFull,
        PtpResponseCode.invalidDevicePropValue,
        PtpResponseCode.devicePropNotSupported,
        PtpResponseCode.captureAlreadyTerminated,
        PtpResponseCode.nikonHardwareError,
        PtpResponseCode.nikonOutOfFocus,
        PtpResponseCode.nikonChangeCameraModeFailed,
        PtpResponseCode.nikonInvalidStatus,
        PtpResponseCode.nikonBulbReleaseBusy,
      ];
      for (final c in mapped) {
        expect(
          debugHintForResponse(c),
          isNotNull,
          reason: '0x${c.toRadixString(16)} should be mapped',
        );
      }
    });
  });
}

/// Runs [body], expects it to throw a [T], returns the thrown instance.
Future<T> _captureThrow<T extends Object>(Future<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    expect(e, isA<T>());
    return e as T;
  }
  fail('expected $T to be thrown');
}
