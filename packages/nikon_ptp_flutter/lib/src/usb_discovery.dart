import 'dart:async';

import 'package:quick_usb/quick_usb.dart';

import 'nikon_usb_ids.dart';

/// One Nikon body found on the USB bus.
///
/// Wraps `quick_usb`'s [UsbDevice] with the friendly model name resolved
/// from [NikonUsbIds]. Serial number is intentionally NOT fetched at
/// discovery time — `UsbDevice.serialNumber` doesn't exist in
/// quick_usb 0.4.0, and pulling it via `getDeviceDescription` would
/// trigger an Android USB permission prompt for every polled scan.
/// Serial lookup happens once at connection time.
final class UsbCameraDescriptor {
  const UsbCameraDescriptor({
    required this.device,
    required this.modelName,
  });

  final UsbDevice device;
  final String modelName;

  /// Stable per-plug string id (in quick_usb 0.4.0 this is the OS-level
  /// device path — survives across App restarts but resets on replug).
  /// Used both as `DiscoveredCamera.id` and as the discriminator when
  /// several Nikon bodies are attached simultaneously.
  String get id => 'usb-${device.identifier}';

  int get vendorId => device.vendorId;
  int get productId => device.productId;

  /// Opaque per-plug identifier — pass this through the routing layer to
  /// `UsbTransport` so it re-selects the same device even in the presence
  /// of multiple Nikons.
  String get identifier => device.identifier;
}

/// Streams Nikon Z bodies currently attached over USB, refreshed on a fixed
/// cadence.
///
/// Why polling rather than a hotplug callback: `quick_usb` doesn't expose
/// Android's `USB_DEVICE_ATTACHED` broadcast to Dart. A ~1-2s poll is
/// cheap (getDeviceList is a syscall, no I/O) and reliable across
/// platforms — the alternative would be a per-platform Pigeon channel,
/// which we can add later if the latency is a problem.
final class UsbCameraDiscovery {
  UsbCameraDiscovery({
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pollInterval = pollInterval;

  final Duration _pollInterval;
  static bool _initialised = false;

  static Future<void> _ensureInit() async {
    if (_initialised) return;
    await QuickUsb.init();
    _initialised = true;
  }

  /// Emits the current attached-Nikon set every [_pollInterval]. Deduplicates
  /// consecutive identical snapshots so listeners aren't woken for no-ops.
  Stream<List<UsbCameraDescriptor>> watch() async* {
    await _ensureInit();
    List<String>? lastSignature;
    while (true) {
      final snapshot = await _scanOnce();
      final sig = snapshot.map((c) => c.id).toList()..sort();
      if (lastSignature == null || !_listEquals(lastSignature, sig)) {
        yield snapshot;
        lastSignature = sig;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  /// One-shot enumeration — useful for manual "refresh" buttons.
  Future<List<UsbCameraDescriptor>> scanOnce() async {
    await _ensureInit();
    return _scanOnce();
  }

  Future<List<UsbCameraDescriptor>> _scanOnce() async {
    final devices = await QuickUsb.getDeviceList();
    final result = <UsbCameraDescriptor>[];
    for (final d in devices) {
      if (!NikonUsbIds.isNikon(d.vendorId)) continue;
      final name = NikonUsbIds.modelFor(d.productId) ??
          'Nikon (PID 0x${d.productId.toRadixString(16).padLeft(4, '0').toUpperCase()})';
      result.add(UsbCameraDescriptor(device: d, modelName: name));
    }
    return result;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
