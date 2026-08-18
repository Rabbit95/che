import 'dart:async';

import 'icc_channel.dart';
import 'pigeon/icc_ptp.g.dart';

/// One camera visible to iOS `ICDeviceBrowser`. Mirrors [UsbCameraDescriptor]'s
/// role but carries the ICA `persistentIDString` instead of a `UsbDevice`
/// handle — iPhone/iPad USB stack is completely opaque to Dart.
final class IccCameraDescriptor {
  const IccCameraDescriptor({
    required this.deviceId,
    required this.modelName,
    required this.transportKind,
    this.serialNumber,
  });

  /// `ICDevice.persistentIDString` — stable across replug and app restarts.
  /// Used as the `iccDeviceId` in [TransportConfig.icc].
  final String deviceId;

  final String modelName;

  /// `'usb'` for wired USB-C, `'network'` for shared cameras, `'unknown'`
  /// when ICA can't tell (rare).
  final String transportKind;

  final String? serialNumber;

  /// Stable per-plug id string for use as `DiscoveredCamera.id`.
  String get id => 'icc-$deviceId';

  factory IccCameraDescriptor.fromPigeon(IccCameraInfo info) {
    return IccCameraDescriptor(
      deviceId: info.deviceId,
      modelName: info.model ?? info.name,
      transportKind: info.transportKind,
      serialNumber: info.serialNumber,
    );
  }
}

/// Streams cameras visible to iOS `ICDeviceBrowser`.
///
/// Unlike [UsbCameraDiscovery] this class does NOT poll. It subscribes to
/// the shared [IccPtpChannel] push callbacks and re-emits the merged
/// snapshot whenever the browser set changes. This is possible because ICA
/// gives us device add/remove callbacks for free — no need to re-scan.
///
/// On non-iOS platforms every method is a no-op that returns an empty
/// snapshot, so the App layer can wire this in unconditionally.
final class IccCameraDiscovery {
  IccCameraDiscovery({IccPtpHostApi? api}) : _api = api ?? IccPtpHostApi();

  final IccPtpHostApi _api;

  /// One-shot enumeration — useful for a manual "refresh" button.
  Future<List<IccCameraDescriptor>> scanOnce() async {
    try {
      final infos = await _api.devices();
      return infos.map(IccCameraDescriptor.fromPigeon).toList();
    } on Object {
      // Non-iOS platforms have no HostApi implementation → MissingPluginException.
      return const <IccCameraDescriptor>[];
    }
  }

  /// Emits the current known-camera set. Fires once immediately with the
  /// initial snapshot, then whenever a device is added or removed.
  Stream<List<IccCameraDescriptor>> watch() {
    late final StreamController<List<IccCameraDescriptor>> controller;
    Future<void> refresh() async {
      if (controller.isClosed) return;
      final snap = await scanOnce();
      controller.add(snap);
    }

    controller = StreamController<List<IccCameraDescriptor>>.broadcast(
      onListen: () async {
        IccPtpChannel.instance.addBrowserListener(refresh);
        final initial = await scanOnce();
        if (!controller.isClosed) controller.add(initial);
      },
      onCancel: () {
        IccPtpChannel.instance.removeBrowserListener(refresh);
      },
    );
    return controller.stream;
  }
}
