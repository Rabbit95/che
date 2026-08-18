// Pigeon schema for the iOS ImageCaptureCore (ICCameraDevice) PTP bridge.
//
// Regenerate with:
//   cd packages/nikon_ptp_flutter
//   dart run pigeon --input pigeons/icc_ptp.dart
//
// Only iOS is a real target — Android USB stays inside the pure-Dart
// UsbTransport (quick_usb_patched). The generated Kotlin is intentionally
// unused; keeping it out keeps the plugin registration on Android empty.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/icc_ptp.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Classes/IccPtpMessages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'nikon_ptp_flutter',
  ),
)
class IccCameraInfo {
  IccCameraInfo({
    required this.deviceId,
    required this.name,
    required this.transportKind,
    this.model,
    this.serialNumber,
    this.isRemote = false,
  });

  /// Stable identifier — `ICDevice.persistentIDString` when available,
  /// otherwise `ICDevice.uuidString`.
  String deviceId;

  /// User-visible product name (`ICDevice.name`).
  String name;

  /// `'usb'` for USB-C wired cameras, `'network'` for shared cameras
  /// (rare on iPhone), `'unknown'` when ICA can't tell.
  String transportKind;

  String? model;
  String? serialNumber;
  bool isRemote;
}

class PtpCommandResult {
  PtpCommandResult({
    required this.responseCode,
    required this.responseParams,
    this.data,
  });

  /// PTP response code (e.g. 0x2001 = OK).
  int responseCode;

  /// Response parameters (0..5 uint32 values).
  List<int> responseParams;

  /// Data-in payload, if the transaction had a data-IN phase.
  Uint8List? data;
}

class PtpCommand {
  PtpCommand({
    required this.opcode,
    required this.transactionId,
    required this.params,
    this.outData,
  });

  /// PTP opcode (e.g. 0x1001 = GetDeviceInfo).
  int opcode;

  /// PTP transaction id; caller-managed.
  int transactionId;

  /// Command parameters (0..5 uint32 values).
  List<int> params;

  /// Data-OUT payload for dataOut transactions, else null.
  Uint8List? outData;
}

@HostApi()
abstract class IccPtpHostApi {
  /// Snapshot of currently-visible ICA camera devices.
  List<IccCameraInfo> devices();

  /// Open an ICA session on the given device. Idempotent — if a session is
  /// already open on the device, returns true immediately.
  @async
  bool openSession(String deviceId);

  /// Send a single PTP command over the currently-open session.
  ///
  /// The native side is responsible for building the PTP command block that
  /// `ICCameraDevice.requestSendPTPCommand(_:outData:sendCommandDelegate:...)`
  /// expects. OpenSession / CloseSession opcodes are intercepted natively —
  /// they never reach ICA (the ICA session lifecycle is managed by
  /// [openSession] / [closeSession] above).
  @async
  PtpCommandResult sendCommand(PtpCommand command);

  /// Close the ICA session on the currently-open device. No-op if none open.
  @async
  void closeSession();
}

@FlutterApi()
abstract class IccPtpFlutterApi {
  /// A new device appeared in the browser.
  void onDeviceAdded(IccCameraInfo device);

  /// A device disappeared (unplug / turned off).
  void onDeviceRemoved(String deviceId);

  /// Push-based PTP event from `ICCameraDeviceDelegate.didReceivePTPEvent:`.
  /// [transactionId] is the container's transaction id (usually 0 for
  /// asynchronous events unrelated to a specific request).
  void onPtpEvent(int eventCode, int transactionId, List<int> params);

  /// The active session ended for a reason other than an explicit close —
  /// device unplugged, camera powered off, or an internal ICA error.
  ///
  /// [reason] is one of: `'unplug'`, `'error'`, `'authRevoked'`, `'timeout'`.
  void onSessionEnded(String deviceId, String reason);

  /// Progress heartbeat during a pending [openSession] call.
  ///
  /// The Swift coordinator emits these at key transitions so the UI can
  /// tell "still waiting on Apple" from "media catalog is 40 % scanned"
  /// from "we hit the watchdog":
  ///
  /// - [phase] `'openSession'` — `requestOpenSession()` was issued and
  ///   we are waiting on `didOpenSessionWithError`. [percent] is `-1`.
  /// - [phase] `'catalog'` — KVO update on
  ///   `ICCameraDevice.contentCatalogPercentCompleted`. [percent] is
  ///   in `[0, 100]`.
  /// - [phase] `'ready'` — `didOpenSessionWithError(nil)` fired.
  ///   [percent] is `100`.
  /// - [phase] `'timeout'` — the 120 s watchdog fired before ICA
  ///   responded. [percent] is `-1`. An `onSessionEnded(reason:'timeout')`
  ///   follows.
  ///
  /// [elapsedMs] is measured from the start of the pending
  /// `openSession` call on the Swift side.
  void onSessionOpenProgress(
    String deviceId,
    String phase,
    int percent,
    int elapsedMs,
  );
}
