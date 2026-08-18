import Flutter
import UIKit
import ImageCaptureCore

/// Flutter plugin entry point. Registers the pigeon `IccPtpHostApi` and
/// holds a single long-lived `IccDeviceCoordinator` that owns the
/// `ICDeviceBrowser` and any currently-open `ICCameraDevice` session.
///
/// iOS 18+ notes:
///
/// - **Wired Accessories permission**: first time a camera is plugged in
///   the system prompts "允许有线配件". Denying it means `ICDeviceBrowser`
///   never fires `didAdd`, so from Dart the discovery list stays empty
///   with no error. Recovery is user-side: 设置 → 隐私与安全 → 有线配件.
///   We deliberately do NOT call the newer
///   `requestControlAuthorization` API — it is iOS 18-only and the
///   system dialog already appears without it on plug-in.
/// - **`ICCameraDevice.mediaFiles`**: known-broken on iPadOS 13.4+ and
///   iOS 18+ (returns empty even when files exist — rdar://FB7593726).
///   We never touch it; browsing goes through PTP `GetObjectHandles`
///   over `requestSendPTPCommand`, which is unaffected.
public class IccPtpPlugin: NSObject, FlutterPlugin {
  private let coordinator: IccDeviceCoordinator

  // PTP opcodes intercepted before hitting ImageCaptureCore. ICA manages
  // the session lifecycle itself (requestOpenSession / requestCloseSession)
  // so we never let PtpSession's own OpenSession/CloseSession commands
  // reach `requestSendPTPCommand` — they'd double-trigger and 0x201E out.
  private static let ptpOpenSessionOpcode: Int64 = 0x1002
  private static let ptpCloseSessionOpcode: Int64 = 0x1003
  private static let ptpResponseOk: Int64 = 0x2001

  init(binaryMessenger: FlutterBinaryMessenger) {
    let flutterApi = IccPtpFlutterApi(binaryMessenger: binaryMessenger)
    self.coordinator = IccDeviceCoordinator(flutterApi: flutterApi)
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = IccPtpPlugin(binaryMessenger: registrar.messenger())
    IccPtpHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin)
    registrar.publish(plugin)
  }
}

extension IccPtpPlugin: IccPtpHostApi {
  func devices() throws -> [IccCameraInfo] {
    return coordinator.snapshot()
  }

  func openSession(
    deviceId: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    coordinator.openSession(deviceId: deviceId, completion: completion)
  }

  func sendCommand(
    command: PtpCommand,
    completion: @escaping (Result<PtpCommandResult, Error>) -> Void
  ) {
    // ImageCaptureCore already opened the ICA session in openSession;
    // the PTP session is implicit. Absorb Dart-side OpenSession/CloseSession
    // and reply with a synthetic OK so PtpSession's handshake completes.
    if command.opcode == Self.ptpOpenSessionOpcode
      || command.opcode == Self.ptpCloseSessionOpcode
    {
      completion(.success(PtpCommandResult(
        responseCode: Self.ptpResponseOk,
        responseParams: [],
        data: nil
      )))
      return
    }

    coordinator.sendPtpCommand(
      opcode: command.opcode,
      txId: command.transactionId,
      params: command.params,
      outData: command.outData?.data,
      completion: completion
    )
  }

  func closeSession(completion: @escaping (Result<Void, Error>) -> Void) {
    coordinator.closeSession(completion: completion)
  }
}
