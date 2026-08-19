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
  ///
  /// Additionally toggles Swift-side "eager pre-open" for the lifetime
  /// of the subscription — the coordinator immediately opens each newly
  /// discovered ICA session and fires a warmup PTP `GetDeviceInfo` in
  /// the background, so by the time the user taps a camera on the
  /// Discovery screen Apple's ~80 s first-command tax has already been
  /// paid. When the last subscriber cancels (Discovery unmounts), eager
  /// pre-open turns off — we don't want to hold the camera in
  /// "connected to PC" mode when the user isn't actively about to
  /// connect. See `IccPtpHostApi.setEagerPreOpen` docs.
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
        // Best-effort — no HostApi on non-iOS platforms yields
        // MissingPluginException, which we silently swallow (matches
        // the scanOnce pattern above).
        try {
          await _api.setEagerPreOpen(true);
        } on Object {
          // Silent: non-iOS host, or plugin not registered.
        }
        final initial = await scanOnce();
        if (!controller.isClosed) controller.add(initial);
      },
      onCancel: () {
        IccPtpChannel.instance.removeBrowserListener(refresh);
        try {
          unawaited(_api.setEagerPreOpen(false));
        } on Object {
          // Silent.
        }
      },
    );
    return controller.stream;
  }
}
