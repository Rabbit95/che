import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'connection_providers.dart';

/// A single row in the parameter sheet — a decoded property descriptor
/// paired with the formatter output the UI actually renders.
@immutable
final class CameraPropertyView {
  const CameraPropertyView({
    required this.propCode,
    required this.desc,
    required this.formattedValue,
    required this.label,
    required this.longName,
  });

  final int propCode;
  final DevicePropDesc desc;

  /// Human-facing current value (e.g. "3200", "1/250", "f/2.8").
  final String formattedValue;

  /// Compact column header used by the exposure strip.
  final String label;

  /// Long name used by the parameter sheet rows.
  final String longName;

  bool get isWritable => desc.isWritable;
}

/// Snapshot of every property the app currently mirrors from the camera.
///
/// Keyed by PTP prop code. Emitted as an immutable map so widgets can
/// `select()` a single prop and rebuild only when that prop changes.
@immutable
final class CameraPropertySnapshot {
  const CameraPropertySnapshot(this.byCode);

  final Map<int, CameraPropertyView> byCode;

  CameraPropertyView? operator [](int propCode) => byCode[propCode];

  static const CameraPropertySnapshot empty =
      CameraPropertySnapshot(<int, CameraPropertyView>{});
}

/// A minimal PTP surface the property watcher needs — narrower than the
/// full [NikonZClient] so tests can supply an in-memory fake without
/// standing up a session/transport pair.
abstract interface class PropertyReader {
  Future<DevicePropDesc> getPropertyDesc(int propCode);
  Stream<CameraEvent> get events;
}

/// Adapter around the real client. Kept trivial on purpose — the client
/// already implements the same shape; this exists only to widen the
/// injection surface for tests.
final class _ClientPropertyReader implements PropertyReader {
  const _ClientPropertyReader(this._client);
  final NikonZClient _client;

  @override
  Future<DevicePropDesc> getPropertyDesc(int propCode) =>
      _client.getPropertyDesc(propCode);

  @override
  Stream<CameraEvent> get events => _client.events;
}

/// Streams the current camera property snapshot, refreshed whenever the
/// camera reports a `devicePropChanged` (0x4006) event *or* on a slow
/// polling tick as a safety net for firmwares that under-report events.
///
/// Polls at 500 ms — matches the M2 acceptance criterion ("camera dial
/// change reflected in ≤500 ms"). Slower than what a UI-driven refresh
/// would want, but the event stream carries the fast path; this is just
/// belt-and-braces against dropped events on Wi-Fi.
final AutoDisposeStreamProvider<CameraPropertySnapshot>
    cameraPropertiesProvider =
    StreamProvider.autoDispose<CameraPropertySnapshot>((ref) {
  final active = ref.watch(activeConnectionProvider);
  if (active == null) {
    return Stream<CameraPropertySnapshot>.value(CameraPropertySnapshot.empty);
  }
  return watchCameraProperties(
    _ClientPropertyReader(active.client),
    active.deviceInfo.devicePropertiesSupported.toSet(),
  );
});

/// Public stream producer used by [cameraPropertiesProvider] and by tests.
///
/// [supportedPropCodes] should be the device's advertised property set;
/// the watcher restricts itself to [kCorePropCodes] ∩ that set.
Stream<CameraPropertySnapshot> watchCameraProperties(
  PropertyReader reader,
  Set<int> supportedPropCodes, {
  Duration pollInterval = const Duration(milliseconds: 500),
}) {
  final targetCodes = kCorePropCodes
      .where(supportedPropCodes.contains)
      .toList(growable: false);

  // If the device advertised none of our core props, still surface an
  // empty snapshot so the UI can show "no properties" instead of hanging.
  if (targetCodes.isEmpty) {
    return Stream<CameraPropertySnapshot>.value(
      CameraPropertySnapshot.empty,
    );
  }

  final ctl = StreamController<CameraPropertySnapshot>();
  final state = <int, CameraPropertyView>{};
  var closed = false;

  Future<void> refreshOne(int code) async {
    if (closed) return;
    try {
      final desc = await reader.getPropertyDesc(code);
      state[code] = CameraPropertyView(
        propCode: code,
        desc: desc,
        formattedValue: PropFormatter.formatValue(code, desc.currentValue),
        label: PropFormatter.labelFor(code),
        longName: PropFormatter.longNameFor(code),
      );
      if (!closed) ctl.add(CameraPropertySnapshot(Map.unmodifiable(state)));
    } on PtpResponseException catch (e) {
      // Skip unsupported / temporarily-denied props; keep going for the rest.
      if (e.code == PtpResponseCode.devicePropNotSupported ||
          e.code == PtpResponseCode.accessDenied ||
          e.code == PtpResponseCode.deviceBusy) {
        return;
      }
      rethrow;
    }
  }

  Future<void> refreshAll() async {
    for (final code in targetCodes) {
      if (closed) return;
      await refreshOne(code);
    }
  }

  StreamSubscription<CameraEvent>? eventsSub;
  Timer? pollTimer;

  Future<void> start() async {
    // Initial full read.
    await refreshAll();

    // Event-driven refresh — devicePropChanged carries the specific prop
    // in p1 when it's a single-prop change, or 0 for "everything changed".
    eventsSub = reader.events.listen((event) {
      if (closed) return;
      if (event.code == StandardEventCode.devicePropChanged) {
        final code = event.p1;
        if (code != 0 && targetCodes.contains(code)) {
          unawaited(refreshOne(code));
        } else {
          unawaited(refreshAll());
        }
      }
    });

    // Polling fallback — drives the "≤500 ms latency" acceptance target
    // even when the transport is dropping events (Wi-Fi in particular).
    pollTimer = Timer.periodic(pollInterval, (_) {
      if (closed) return;
      unawaited(refreshAll());
    });
  }

  ctl
    ..onListen = () {
      unawaited(start());
    }
    ..onCancel = () async {
      closed = true;
      pollTimer?.cancel();
      await eventsSub?.cancel();
      pollTimer = null;
      eventsSub = null;
    };

  return ctl.stream;
}

/// Convenience — grabs one prop by code from the current snapshot.
///
/// Widgets that only care about a single prop can `ref.watch` this
/// provider family to avoid rebuilding when siblings change.
final AutoDisposeProviderFamily<CameraPropertyView?, int> cameraPropertyProvider =
    Provider.autoDispose.family<CameraPropertyView?, int>((ref, propCode) {
  final snapshot = ref.watch(cameraPropertiesProvider).valueOrNull;
  return snapshot?[propCode];
});
