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
/// (iOS goes through ICCameraDevice via a different Pigeon channel; that
/// wiring lands with the M6 iOS story.)
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

/// Union of every discovery source. Merges USB (real, from quick_usb) with
/// mDNS Wi-Fi cameras — the mDNS side is still stubbed in M1.
final StreamProvider<List<DiscoveredCamera>> discoveryProvider =
    StreamProvider<List<DiscoveredCamera>>((ref) {
  final usbAsync = ref.watch(usbCameraDiscoveryProvider);
  return Stream.value(<DiscoveredCamera>[
    ...usbAsync.maybeWhen(
      data: (usb) => usb.map(_usbToDiscovered),
      orElse: () => const <DiscoveredCamera>[],
    ),
    // TODO(M1): replace this stub with a Bonsoir _ptp._tcp stream.
    const DiscoveredCamera(
      id: 'nikon-z6iii-wifi-demo',
      name: 'Nikon Z6III (Wi-Fi 示例)',
      channel: TransportChannel.wifi,
      host: '192.168.1.1',
      signalBars: 3,
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
