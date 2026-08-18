import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_z_control/shared/providers/live_view_provider.dart';

/// Fake LV source with programmable frame supply and start/stop tracing.
class _FakeSource implements LiveViewSource {
  bool started = false;
  bool stopped = false;
  int startCalls = 0;
  int stopCalls = 0;
  int frameCalls = 0;
  Object? startError;
  Object? frameError; // one-shot: cleared after being thrown once
  final _frames = <LiveViewFrame?>[];

  void seedFrame({DateTime? timestamp}) {
    _frames.add(LiveViewFrame(
      jpeg: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      header: const LvHeader(),
      timestamp: timestamp ?? DateTime.timestamp(),
    ));
  }

  void seedNull() => _frames.add(null);

  @override
  Future<void> startLiveView() async {
    startCalls++;
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  Future<void> stopLiveView() async {
    stopCalls++;
    stopped = true;
  }

  @override
  Future<LiveViewFrame?> getLiveViewFrameDecoded() async {
    frameCalls++;
    if (frameError != null) {
      final err = frameError!;
      frameError = null;
      throw err;
    }
    if (_frames.isEmpty) return null;
    return _frames.removeAt(0);
  }
}

void main() {
  group('runLiveView', () {
    test('emits starting → running → frame states in order', () async {
      final source = _FakeSource()
        ..seedFrame()
        ..seedFrame();

      final stream = runLiveView(source, targetFps: 60);
      final events = <LiveViewState>[];
      final sub = stream.listen(events.add);

      // Give the loop a beat to reach running + a couple of frames.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();

      expect(events.first.status, LiveViewStatus.starting);
      expect(source.started, isTrue);
      expect(events.any((e) => e.status == LiveViewStatus.running), isTrue);
      expect(events.any((e) => e.frame != null), isTrue);
      // Cancel triggered stopLiveView.
      expect(source.stopCalls, 1);
    });

    test('publishes error state when startLiveView throws', () async {
      final source = _FakeSource()
        ..startError = const PtpResponseException(
          PtpResponseCode.deviceBusy,
          opcode: NikonOpcode.startLiveView,
        );

      final stream = runLiveView(source, targetFps: 60);
      final events = <LiveViewState>[];
      final sub = stream.listen(events.add);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();

      expect(
        events.any((e) =>
            e.status == LiveViewStatus.error &&
            e.error is PtpResponseException),
        isTrue,
      );
      // We never entered the running loop, so stopLiveView shouldn't
      // fire — spending a bulk command on a session that never started
      // just wastes latency.
      expect(source.stopCalls, 0);
    });

    test('single-frame error keeps stream alive', () async {
      final source = _FakeSource()
        ..frameError = Exception('bad frame')
        ..seedFrame();

      final stream = runLiveView(source, targetFps: 60);
      final events = <LiveViewState>[];
      final sub = stream.listen(events.add);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      // Recovered after the bad frame and produced a real one.
      expect(events.any((e) => e.frame != null), isTrue);
    });

    test('measured fps rises above zero once we have >=2 frames', () async {
      final t0 = DateTime.timestamp();
      final source = _FakeSource()
        ..seedFrame(timestamp: t0)
        ..seedFrame(timestamp: t0.add(const Duration(milliseconds: 50)))
        ..seedFrame(timestamp: t0.add(const Duration(milliseconds: 100)));

      final stream = runLiveView(source, targetFps: 60);
      final events = <LiveViewState>[];
      final sub = stream.listen(events.add);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      expect(events.any((e) => e.measuredFps > 0), isTrue);
    });

    test('cancel calls stopLiveView exactly once', () async {
      final source = _FakeSource()..seedFrame();
      final stream = runLiveView(source, targetFps: 60);
      final sub = stream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(source.stopCalls, 1);
    });

    test('null frames from a warming camera are silently skipped', () async {
      final source = _FakeSource()
        ..seedNull()
        ..seedNull()
        ..seedFrame();

      final stream = runLiveView(source, targetFps: 60);
      final events = <LiveViewState>[];
      final sub = stream.listen(events.add);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      // We eventually saw a real frame, and the stream never entered
      // the error state just because early ticks were empty.
      expect(events.any((e) => e.frame != null), isTrue);
      expect(events.every((e) => e.status != LiveViewStatus.error), isTrue);
    });
  });
}
