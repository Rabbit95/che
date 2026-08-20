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
    _cached?._sessionOpenProgressListener = null;
    _cached?._diagnosticLogListener = null;
    _cached?._diagnosticLogBuffer.clear();
    _cached = null;
  }

  // Browser watchers — many can be active at once (multiple UI widgets).
  final List<Future<void> Function()> _browserListeners = [];

  // Session event routers — at most one active session at a time on iOS.
  void Function(int eventCode, int transactionId, List<int> params)?
      _ptpEventListener;
  void Function(String deviceId, String reason)? _sessionEndedListener;
  void Function(
    String deviceId,
    String phase,
    int percent,
    int elapsedMs,
  )? _sessionOpenProgressListener;
  void Function(String tag, String message, int elapsedMs)?
      _diagnosticLogListener;

  /// Ring buffer of recent Swift-side diagnostic logs. Swift emits log
  /// lines from `IccDeviceCoordinator.init()` and `setEagerPreOpen(true)`
  /// (Discovery mount time) which fire BEFORE a listener attaches from
  /// `IccTransport.open()` (user tap time). Without buffering, those
  /// early lines — including the crucial `auth.control.status` — would
  /// be dropped and never reach the in-app copy log.
  ///
  /// When a listener attaches, the buffer is replayed to it, so the
  /// user's copied log always contains the full trace back through the
  /// last N events (capped at [_maxDiagnosticLogBuffer]).
  static const int _maxDiagnosticLogBuffer = 200;
  final List<_DiagnosticLogEntry> _diagnosticLogBuffer = [];

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

  void setSessionOpenProgressListener(
    void Function(
      String deviceId,
      String phase,
      int percent,
      int elapsedMs,
    )? cb,
  ) {
    _sessionOpenProgressListener = cb;
  }

  void setDiagnosticLogListener(
    void Function(String tag, String message, int elapsedMs)? cb,
  ) {
    _diagnosticLogListener = cb;
    if (cb != null) {
      // Replay buffered entries so listeners attaching late (e.g. after
      // Discovery mount) still see the init-time + Discovery-time logs
      // (auth.control.status, eager.setEnabled, browser.init).
      for (final entry in _diagnosticLogBuffer) {
        cb(entry.tag, entry.message, entry.elapsedMs);
      }
    }
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

  @override
  void onSessionOpenProgress(
    String deviceId,
    String phase,
    int percent,
    int elapsedMs,
  ) {
    _sessionOpenProgressListener?.call(deviceId, phase, percent, elapsedMs);
  }

  @override
  void onDiagnosticLog(String tag, String message, int elapsedMs) {
    _diagnosticLogBuffer.add(_DiagnosticLogEntry(tag, message, elapsedMs));
    if (_diagnosticLogBuffer.length > _maxDiagnosticLogBuffer) {
      _diagnosticLogBuffer.removeAt(0);
    }
    _diagnosticLogListener?.call(tag, message, elapsedMs);
  }

  Future<void> _fanoutBrowser() async {
    for (final cb in List.of(_browserListeners)) {
      await cb();
    }
  }
}

class _DiagnosticLogEntry {
  const _DiagnosticLogEntry(this.tag, this.message, this.elapsedMs);
  final String tag;
  final String message;
  final int elapsedMs;
}
