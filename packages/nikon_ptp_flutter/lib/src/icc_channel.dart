import 'pigeon/icc_ptp.g.dart';

/// Singleton fan-out for the iOS `IccPtpFlutterApi` push channel.
///
/// Both [IccCameraDiscovery] (browser callbacks) and [IccTransport] (PTP
/// event push + session-end) need to receive these callbacks, but pigeon
/// only lets us install one `FlutterApi` handler per channel. This class
/// is that handler, and demultiplexes to the interested parties.
///
/// Lazily wires itself up on first access — access is a no-op on non-iOS
/// where the native side of the channel is absent.
final class IccPtpChannel implements IccPtpFlutterApi {
  IccPtpChannel._();

  static IccPtpChannel? _cached;

  static IccPtpChannel get instance {
    final existing = _cached;
    if (existing != null) return existing;
    final created = IccPtpChannel._();
    IccPtpFlutterApi.setUp(created);
    _cached = created;
    return created;
  }

  /// Drop the cached singleton and clear any registered listeners.
  ///
  /// Intended for tests that want to verify behaviour across a fresh
  /// channel. Do not call from production code — the pigeon `setUp` call
  /// in `instance` is idempotent per binaryMessenger but not free.
  static void resetForTesting() {
    _cached?._browserListeners.clear();
    _cached?._ptpEventListener = null;
    _cached?._sessionEndedListener = null;
    _cached = null;
  }

  // Browser watchers — many can be active at once (multiple UI widgets).
  final List<Future<void> Function()> _browserListeners = [];

  // Session event routers — at most one active session at a time on iOS.
  void Function(int eventCode, int transactionId, List<int> params)?
      _ptpEventListener;
  void Function(String deviceId, String reason)? _sessionEndedListener;

  void addBrowserListener(Future<void> Function() cb) {
    _browserListeners.add(cb);
  }

  void removeBrowserListener(Future<void> Function() cb) {
    _browserListeners.remove(cb);
  }

  void setPtpEventListener(
    void Function(int eventCode, int transactionId, List<int> params)? cb,
  ) {
    _ptpEventListener = cb;
  }

  void setSessionEndedListener(
    void Function(String deviceId, String reason)? cb,
  ) {
    _sessionEndedListener = cb;
  }

  @override
  void onDeviceAdded(IccCameraInfo device) {
    _fanoutBrowser();
  }

  @override
  void onDeviceRemoved(String deviceId) {
    _fanoutBrowser();
  }

  @override
  void onPtpEvent(int eventCode, int transactionId, List<int> params) {
    _ptpEventListener?.call(eventCode, transactionId, params);
  }

  @override
  void onSessionEnded(String deviceId, String reason) {
    _sessionEndedListener?.call(deviceId, reason);
  }

  Future<void> _fanoutBrowser() async {
    for (final cb in List.of(_browserListeners)) {
      await cb();
    }
  }
}
