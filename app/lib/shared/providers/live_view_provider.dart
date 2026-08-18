import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'connection_providers.dart';

/// Runtime status of the Live View pipeline.
///
/// The UI can render a spinner on [starting], show the frame stream on
/// [running], and switch to an error surface on [error]. `stopped` is the
/// default when no connection is active or the stream was cancelled.
enum LiveViewStatus { stopped, starting, running, error }

/// One published tick of the Live View pipeline.
///
/// [frame] is the most recently decoded [LiveViewFrame] (or null while
/// warming up), [measuredFps] is the rolling frame-per-second reading
/// derived from recent frame timestamps, and [status] tracks the state
/// machine for banner UI.
@immutable
final class LiveViewState {
  const LiveViewState({
    required this.status,
    this.frame,
    this.measuredFps = 0,
    this.error,
  });

  final LiveViewStatus status;
  final LiveViewFrame? frame;
  final double measuredFps;
  final Object? error;

  static const LiveViewState idle = LiveViewState(status: LiveViewStatus.stopped);

  LiveViewState copyWith({
    LiveViewStatus? status,
    LiveViewFrame? frame,
    double? measuredFps,
    Object? error,
    bool clearError = false,
    bool clearFrame = false,
  }) {
    return LiveViewState(
      status: status ?? this.status,
      frame: clearFrame ? null : (frame ?? this.frame),
      measuredFps: measuredFps ?? this.measuredFps,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Minimal surface the LV runner needs from the client — narrowed so
/// tests can drop in an in-memory fake.
abstract interface class LiveViewSource {
  Future<void> startLiveView();
  Future<void> stopLiveView();
  Future<LiveViewFrame?> getLiveViewFrameDecoded();
}

/// Adapter around [NikonZClient]. Trivial by design.
final class _ClientLiveViewSource implements LiveViewSource {
  const _ClientLiveViewSource(this._client);
  final NikonZClient _client;

  @override
  Future<void> startLiveView() => _client.startLiveView();

  @override
  Future<void> stopLiveView() => _client.stopLiveView();

  @override
  Future<LiveViewFrame?> getLiveViewFrameDecoded() =>
      _client.getLiveViewFrameDecoded();
}

/// Live View state stream — starts LV on the active connection, polls
/// frames at up to [targetFps], and shuts LV down cleanly on cancel.
///
/// Poll cadence is self-timed: each cycle sleeps for `max(0, tick -
/// lastCallCost)` so a slow camera doesn't bunch requests on the same
/// tick and we don't burn CPU on a stuck one.
///
/// The provider is `autoDispose` — pop the screen and LV stops. Consumers
/// that need to keep it warm across a navigation should attach a keepAlive
/// link at the callsite.
final AutoDisposeStreamProvider<LiveViewState> liveViewProvider =
    StreamProvider.autoDispose<LiveViewState>((ref) {
  final active = ref.watch(activeConnectionProvider);
  if (active == null) {
    return Stream<LiveViewState>.value(LiveViewState.idle);
  }
  final targetFps = active.client.quirks?.liveViewMaxFps ?? 30;
  return runLiveView(
    _ClientLiveViewSource(active.client),
    targetFps: targetFps,
  );
});

/// Live View runner exposed for tests. Handles start / poll / stop and
/// the rolling FPS calculation.
///
/// [targetFps] caps how frequently we ask the camera for a frame; the
/// actual measured rate lands lower when the camera is slow.
Stream<LiveViewState> runLiveView(
  LiveViewSource source, {
  int targetFps = 30,
  int fpsWindow = 16,
}) {
  assert(targetFps > 0, 'targetFps must be positive');
  final tick = Duration(microseconds: 1000000 ~/ targetFps);
  final ctl = StreamController<LiveViewState>();

  var state = const LiveViewState(status: LiveViewStatus.starting);
  final frameStamps = <DateTime>[];
  var closed = false;
  var running = false;

  double measureFps() {
    if (frameStamps.length < 2) return 0;
    final span = frameStamps.last.difference(frameStamps.first);
    if (span.inMicroseconds <= 0) return 0;
    return (frameStamps.length - 1) * 1000000 / span.inMicroseconds;
  }

  void publish(LiveViewState next) {
    if (closed || ctl.isClosed) return;
    state = next;
    ctl.add(next);
  }

  Future<void> runLoop() async {
    try {
      await source.startLiveView();
    } catch (e) {
      publish(state.copyWith(status: LiveViewStatus.error, error: e));
      return;
    }
    if (closed) return;
    publish(state.copyWith(status: LiveViewStatus.running, clearError: true));
    running = true;

    while (!closed) {
      final started = DateTime.timestamp();
      try {
        final frame = await source.getLiveViewFrameDecoded();
        if (closed) break;
        if (frame != null) {
          frameStamps.add(frame.timestamp);
          if (frameStamps.length > fpsWindow) {
            frameStamps.removeAt(0);
          }
          publish(state.copyWith(
            status: LiveViewStatus.running,
            frame: frame,
            measuredFps: measureFps(),
            clearError: true,
          ),);
        }
      } catch (e) {
        // Transient errors (a single dropped frame) shouldn't tear the
        // stream down — surface the last error but keep looping.
        publish(state.copyWith(error: e));
      }

      final spent = DateTime.timestamp().difference(started);
      final wait = tick - spent;
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
  }

  ctl
    ..onListen = () {
      publish(state);
      unawaited(runLoop());
    }
    ..onCancel = () async {
      closed = true;
      if (running) {
        try {
          await source.stopLiveView();
        } catch (_) {
          // Best-effort — session might already be torn down. Swallowing
          // here is fine; the transport layer surfaces real problems.
        }
      }
    };

  return ctl.stream;
}
