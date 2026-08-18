import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

/// One Nikon body advertising itself on the local network via mDNS.
///
/// Wraps a [ResolvedBonsoirService] with the model name already parsed out
/// of the service name. Nikon Z bodies (and other PTP/IP cameras) announce
/// themselves under `_ptp._tcp` per the PIMA 15740 PTP-IP addendum; the
/// service name is typically the camera's friendly model, e.g.
/// `"NIKON Z6III"` or `"Z8-1234567"`.
final class WifiCameraDescriptor {
  const WifiCameraDescriptor({
    required this.name,
    required this.host,
    required this.port,
    this.attributes = const <String, String>{},
  });

  /// Friendly name from the mDNS service record. Never empty.
  final String name;

  /// Resolved host — an IPv4 dotted quad or IPv6 literal on Android/iOS.
  /// Never `null` for a descriptor emitted by [WifiCameraDiscovery]; the
  /// discovery layer drops entries that fail to resolve.
  final String host;

  final int port;

  /// TXT record attributes. Nikon Z bodies don't currently populate this,
  /// but future firmware or third-party bridges (e.g. gPhoto-Web) might.
  final Map<String, String> attributes;

  /// Stable id string for use as `DiscoveredCamera.id`. mDNS names are
  /// unique within a service type on a given link, so this is safe as long
  /// as we don't cross service-type boundaries — we don't.
  String get id => 'wifi-$name';

  @override
  bool operator ==(Object other) =>
      other is WifiCameraDescriptor &&
      other.name == name &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, host, port);
}

/// Thin abstraction over the pieces of [BonsoirDiscovery] that
/// [WifiCameraDiscovery] actually touches. Extracted so tests can drive
/// the discovery lifecycle without spinning up a real platform channel
/// (Bonsoir talks to `NSNetServiceBrowser` / `NsdManager`, neither of
/// which exists in a Flutter unit-test binding).
///
/// The default production implementation wraps a real [BonsoirDiscovery].
abstract interface class WifiDiscoveryHandle {
  Future<void> ready();
  Future<void> start();
  Future<void> stop();

  /// True after [stop] has run — matches [BonsoirDiscovery.isStopped].
  bool get isStopped;

  /// Kick off the async resolve for the given service. Errors from the
  /// underlying resolver are silently absorbed by the caller.
  Future<void> resolve(BonsoirService service);

  /// Event stream — may be null before [ready] completes.
  Stream<BonsoirDiscoveryEvent>? get eventStream;
}

/// Streams Nikon bodies visible on the local network via Bonjour/mDNS.
///
/// Subscribes to one [BonsoirDiscovery] per service type (defaults to just
/// `_ptp._tcp` — the standard PIMA 15740 PTP-IP advertisement). Add
/// `_nikon._tcp` to [serviceTypes] if you want to catch bodies advertising
/// under Nikon's proprietary type (rare — SnapBridge itself uses BLE and
/// then jumps straight to a TCP session without advertising).
///
/// Design mirrors [IccCameraDiscovery]:
///   - No polling. mDNS is push-based; we react to `serviceFound` /
///     `serviceResolved` / `serviceLost` callbacks.
///   - `serviceFound` is followed by an explicit `resolve()` — the raw
///     service has no host until then. Only `serviceResolved` events flip
///     an entry into the emitted snapshot.
///   - Snapshot list is de-duplicated by mDNS service name (the record's
///     unique key). Multiple service types (`_ptp._tcp`, `_nikon._tcp`)
///     advertising the same body collapse to one entry, first-writer-wins.
class WifiCameraDiscovery {
  WifiCameraDiscovery({
    List<String>? serviceTypes,
    WifiDiscoveryHandle Function(String type)? discoveryFactory,
  })  : _serviceTypes = List<String>.unmodifiable(
          serviceTypes ?? const ['_ptp._tcp'],
        ),
        _discoveryFactory = discoveryFactory ?? _defaultBonsoirDiscoveryFactory;

  final List<String> _serviceTypes;
  final WifiDiscoveryHandle Function(String) _discoveryFactory;

  /// Non-broadcast controller — a new controller is created per [watch]
  /// call so cancel semantics are clean.
  StreamController<List<WifiCameraDescriptor>>? _controller;

  /// Live discovery handles, one per service type.
  final List<WifiDiscoveryHandle> _discoveries = <WifiDiscoveryHandle>[];
  final List<StreamSubscription<BonsoirDiscoveryEvent>> _subs =
      <StreamSubscription<BonsoirDiscoveryEvent>>[];

  /// Keyed by mDNS service name (unique within a service type on a link).
  /// A missing entry means "found but not yet resolved" — those don't
  /// appear in emitted snapshots.
  final Map<String, WifiCameraDescriptor> _resolved =
      <String, WifiCameraDescriptor>{};

  static WifiDiscoveryHandle _defaultBonsoirDiscoveryFactory(String type) =>
      _BonsoirWifiHandle(BonsoirDiscovery(type: type));

  /// Emits the current known-camera set. Fires an initial empty snapshot
  /// synchronously so listeners can render a placeholder immediately, then
  /// updates whenever a body appears, resolves, or leaves.
  ///
  /// On non-Android/iOS/macOS platforms Bonsoir throws
  /// [MissingPluginException] the moment we touch it; we swallow that and
  /// emit an empty snapshot forever — the App layer merges this with USB
  /// and ICC discoveries, so a missing Wi-Fi source is a valid state.
  Stream<List<WifiCameraDescriptor>> watch() {
    final controller = StreamController<List<WifiCameraDescriptor>>(
      onListen: _start,
      onCancel: _stop,
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _start() async {
    // Emit an initial empty snapshot synchronously — the App's
    // `discoveryProvider` merges multiple sources, and having an
    // immediate `AsyncData([])` from Wi-Fi keeps the merged provider from
    // sitting in `loading` forever when the platform has no plugin.
    _emit();
    for (final type in _serviceTypes) {
      try {
        await _startOne(type);
      } on Object catch (e, st) {
        // Bonsoir failing for one type shouldn't kill the others (e.g. a
        // proprietary `_nikon._tcp` may be blocked by iOS 14+
        // NSBonjourServices while `_ptp._tcp` is allowed). Log and
        // continue — swallowing is intentional; the controller stays open
        // so the App still merges the empty snapshot.
        _addError(e, st);
      }
    }
  }

  Future<void> _startOne(String type) async {
    final handle = _discoveryFactory(type);
    _discoveries.add(handle);
    await handle.ready();
    final stream = handle.eventStream;
    if (stream == null) return;
    _subs.add(stream.listen(
      (event) => _onEvent(handle, event),
      onError: _addError,
    ));
    await handle.start();
  }

  void _onEvent(WifiDiscoveryHandle handle, BonsoirDiscoveryEvent event) {
    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        final service = event.service;
        if (service == null) return;
        // Kick off the async resolve — bonsoir will emit
        // `discoveryServiceResolved` (or the failed variant) when done.
        unawaited(handle.resolve(service).catchError((Object _) {}));
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        final service = event.service;
        if (service is! ResolvedBonsoirService) return;
        final host = service.host;
        if (host == null || host.isEmpty) return;
        _resolved[service.name] = WifiCameraDescriptor(
          name: service.name,
          host: host,
          port: service.port,
          attributes: Map<String, String>.unmodifiable(service.attributes),
        );
        _emit();
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        final service = event.service;
        if (service == null) return;
        if (_resolved.remove(service.name) != null) _emit();
      case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
      case BonsoirDiscoveryEventType.discoveryStarted:
      case BonsoirDiscoveryEventType.discoveryStopped:
      case BonsoirDiscoveryEventType.unknown:
        break;
    }
  }

  void _emit() {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.add(List.unmodifiable(_resolved.values));
  }

  void _addError(Object error, [StackTrace? stackTrace]) {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.addError(error, stackTrace);
  }

  Future<void> _stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final d in _discoveries) {
      try {
        if (!d.isStopped) await d.stop();
      } on Object {
        // Best-effort — nothing sensible to do on a stop failure.
      }
    }
    _discoveries.clear();
    _resolved.clear();
    final controller = _controller;
    _controller = null;
    await controller?.close();
  }
}

/// Production adapter that maps [WifiDiscoveryHandle] onto a real
/// [BonsoirDiscovery]. Kept inline so tests don't accidentally import it.
final class _BonsoirWifiHandle implements WifiDiscoveryHandle {
  _BonsoirWifiHandle(this._discovery);

  final BonsoirDiscovery _discovery;

  @override
  Future<void> ready() => _discovery.ready;

  @override
  Future<void> start() => _discovery.start();

  @override
  Future<void> stop() => _discovery.stop();

  @override
  bool get isStopped => _discovery.isStopped;

  @override
  Future<void> resolve(BonsoirService service) =>
      service.resolve(_discovery.serviceResolver);

  @override
  Stream<BonsoirDiscoveryEvent>? get eventStream => _discovery.eventStream;
}
