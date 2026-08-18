import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_ptp_flutter/nikon_ptp_flutter.dart';

/// Descriptor of a camera discovered on the local network or over USB.
final class DiscoveredCamera {
  const DiscoveredCamera({
    required this.id,
    required this.name,
    required this.channel,
    this.host,
    this.serialNumber,
    this.signalBars,
    this.firmware,
    this.usbSerial,
    this.iccDeviceId,
  });

  final String id;
  final String name;
  final TransportChannel channel;
  final String? host;
  final String? serialNumber;
  final int? signalBars; // 0..4 (Wi-Fi)
  final String? firmware;

  /// USB serial number, used to disambiguate when several Nikons are plugged
  /// into the same host — separate from [serialNumber] because a USB device
  /// serial isn't always the same as the camera body serial reported by
  /// GetDeviceInfo.
  final String? usbSerial;

  /// iOS `ICDevice.persistentIDString` — set only for
  /// [TransportChannel.icc] entries discovered via
  /// [IccCameraDiscovery].
  final String? iccDeviceId;
}

/// Snapshot of the active connection — feeds the app-wide status chip.
final class ActiveConnection {
  const ActiveConnection({
    required this.camera,
    required this.deviceInfo,
    required this.client,
  });

  final DiscoveredCamera camera;
  final DeviceInfo deviceInfo;
  final NikonZClient client;
}

/// Stream of Nikon bodies currently visible on the USB bus.
///
/// Enabled only on desktop + Android — Web / iOS return an empty stream.
/// iOS goes through ICCameraDevice (see [iccCameraDiscoveryProvider]).
final StreamProvider<List<UsbCameraDescriptor>> usbCameraDiscoveryProvider =
    StreamProvider<List<UsbCameraDescriptor>>((ref) {
  if (kIsWeb) return const Stream.empty();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return UsbCameraDiscovery().watch();
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return const Stream.empty();
  }
});

/// Stream of Nikon bodies visible via iOS `ICDeviceBrowser` (USB-C on
/// iPhone/iPad). Enabled only on iOS — everything else returns empty.
final StreamProvider<List<IccCameraDescriptor>> iccCameraDiscoveryProvider =
    StreamProvider<List<IccCameraDescriptor>>((ref) {
  if (kIsWeb) return const Stream.empty();
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    return const Stream.empty();
  }
  return IccCameraDiscovery().watch();
});

/// Stream of Nikon bodies advertising themselves on the local network via
/// mDNS (`_ptp._tcp`, the PIMA 15740 PTP-IP standard type).
///
/// Enabled on Android + iOS + macOS. Web / Windows / Linux fall through
/// with an empty stream — Bonsoir supports Windows/Linux via its own
/// plugins but we haven't validated them against a Nikon body yet, and
/// on the target platforms the App is bound to Android/iOS anyway.
final StreamProvider<List<WifiCameraDescriptor>> wifiCameraDiscoveryProvider =
    StreamProvider<List<WifiCameraDescriptor>>((ref) {
  if (kIsWeb) return const Stream.empty();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return WifiCameraDiscovery().watch();
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return const Stream.empty();
  }
});

/// Union of every discovery source. Merges USB (Android/desktop, quick_usb),
/// ICC (iOS, ImageCaptureCore), and mDNS Wi-Fi (bonsoir `_ptp._tcp`).
final StreamProvider<List<DiscoveredCamera>> discoveryProvider =
    StreamProvider<List<DiscoveredCamera>>((ref) {
  final usbAsync = ref.watch(usbCameraDiscoveryProvider);
  final iccAsync = ref.watch(iccCameraDiscoveryProvider);
  final wifiAsync = ref.watch(wifiCameraDiscoveryProvider);
  return Stream.value(<DiscoveredCamera>[
    ...usbAsync.maybeWhen(
      data: (usb) => usb.map(_usbToDiscovered),
      orElse: () => const <DiscoveredCamera>[],
    ),
    ...iccAsync.maybeWhen(
      data: (icc) => icc.map(_iccToDiscovered),
      orElse: () => const <DiscoveredCamera>[],
    ),
    ...wifiAsync.maybeWhen(
      data: (wifi) => wifi.map(_wifiToDiscovered),
      orElse: () => const <DiscoveredCamera>[],
    ),
  ]);
});

DiscoveredCamera _usbToDiscovered(UsbCameraDescriptor d) {
  // quick_usb 0.4.0's UsbDevice doesn't expose a real serial number without
  // calling getDeviceDescription (which triggers Android permission dialogs).
  // We route the opaque device identifier through `usbSerial` so the
  // transport can re-select the same device when several Nikons are
  // attached; the human-visible SN stays null until the connection opens
  // and GetDeviceInfo returns it.
  return DiscoveredCamera(
    id: d.id,
    name: d.modelName,
    channel: TransportChannel.usb,
    usbSerial: d.identifier,
  );
}

DiscoveredCamera _iccToDiscovered(IccCameraDescriptor d) {
  return DiscoveredCamera(
    id: d.id,
    name: d.modelName,
    channel: TransportChannel.icc,
    serialNumber: d.serialNumber,
    iccDeviceId: d.deviceId,
  );
}

DiscoveredCamera _wifiToDiscovered(WifiCameraDescriptor d) {
  return DiscoveredCamera(
    id: d.id,
    name: d.name,
    channel: TransportChannel.wifi,
    host: d.host,
    // signalBars is intentionally left null — mDNS gives us no radio
    // signal metric, only Wi-Fi framework APIs can, and requiring those
    // permissions just for a bar count isn't worth it.
  );
}

/// Camera-list history — offline devices seen in past sessions.
///
/// TODO(M5): persist to shared_preferences so it survives restarts.
final Provider<List<DiscoveredCamera>> recentCamerasProvider =
    Provider<List<DiscoveredCamera>>((ref) {
  return const <DiscoveredCamera>[];
});

/// Currently connected camera + client, or null when disconnected.
final StateProvider<ActiveConnection?> activeConnectionProvider =
    StateProvider<ActiveConnection?>((ref) => null);

/// Side-effect provider that keeps `activeConnectionProvider` honest.
///
/// When a session becomes active it subscribes to the transport's state
/// changes and, on `failed` or `closed`, wipes the active connection.
/// Screens that watch [activeConnectionProvider] can then react — the
/// LiveView screen bounces back to Discovery, the app-wide status chip
/// clears, etc.
///
/// Watch this once at the app root so its subscription lives for the
/// process lifetime.
final Provider<void> transportDisconnectWatcherProvider = Provider<void>((ref) {
  StreamSubscription<TransportState>? sub;
  ref.onDispose(() => sub?.cancel());

  ref.listen<ActiveConnection?>(activeConnectionProvider, (prev, next) {
    sub?.cancel();
    sub = null;
    if (next == null) return;
    sub = next.client.session.transport.stateChanges.listen((state) {
      if (state != TransportState.failed &&
          state != TransportState.closed) {
        return;
      }
      // Only clear if this connection is still the current one — a
      // late-fired event from a stale transport must not stomp a
      // freshly-opened session.
      if (identical(ref.read(activeConnectionProvider), next)) {
        ref.read(activeConnectionProvider.notifier).state = null;
      }
    });
  }, fireImmediately: true);
});
