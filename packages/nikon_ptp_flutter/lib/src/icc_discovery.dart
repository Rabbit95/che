import 'dart:async';

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
/// Unlike [UsbCameraDiscovery] this class does NOT poll. It subscribes once
/// to the native `IccPtpFlutterApi` push callbacks and re-emits the merged
/// snapshot whenever the set changes. This is possible because ICA gives us
/// device add/remove callbacks for free — no need to re-scan.
///
/// On non-iOS platforms every method is a no-op that returns an empty
/// snapshot, so the App layer can wire this in unconditionally.
final class IccCameraDiscovery {
  IccCameraDiscovery({IccPtpHostApi? api}) : _api = api ?? IccPtpHostApi() {
    _registerFlutterApi();
  }

  final IccPtpHostApi _api;
  static _IccBrowserSink? _sharedSink;

  StreamController<List<IccCameraDescriptor>>? _controller;

  void _registerFlutterApi() {
    if (_sharedSink != null) return;
    final sink = _IccBrowserSink();
    IccPtpFlutterApi.setUp(sink);
    _sharedSink = sink;
  }

  /// One-shot enumeration — useful for a manual "refresh" button.
  ///
  /// Returns an empty list on non-iOS platforms (Phase A stub also returns
  /// empty on iOS until the ICDeviceBrowser is wired in Phase B).
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
    final controller = StreamController<List<IccCameraDescriptor>>.broadcast(
      onListen: () async {
        final initial = await scanOnce();
        _controller?.add(initial);
      },
    );
    _controller = controller;
    _sharedSink?.registerListener(() async {
      if (controller.isClosed) return;
      final snap = await scanOnce();
      controller.add(snap);
    });
    return controller.stream;
  }
}

/// Fan-out sink for `IccPtpFlutterApi` callbacks — a single native subscription
/// serves any number of Dart-side [IccCameraDiscovery] listeners.
class _IccBrowserSink implements IccPtpFlutterApi {
  final List<Future<void> Function()> _listeners = [];

  void registerListener(Future<void> Function() cb) {
    _listeners.add(cb);
  }

  Future<void> _fanout() async {
    for (final cb in List.of(_listeners)) {
      await cb();
    }
  }

  @override
  void onDeviceAdded(IccCameraInfo device) {
    _fanout();
  }

  @override
  void onDeviceRemoved(String deviceId) {
    _fanout();
  }

  @override
  void onPtpEvent(int eventCode, List<int> params) {
    // Phase D routes this into IccTransport.events; Phase A drops it.
  }

  @override
  void onSessionEnded(String deviceId, String reason) {
    // Phase D routes this into IccTransport state.
  }
}
