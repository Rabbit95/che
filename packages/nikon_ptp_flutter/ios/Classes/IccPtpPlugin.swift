import Flutter
import UIKit
import ImageCaptureCore

/// Flutter plugin entry point. Registers the pigeon `IccPtpHostApi` and
/// holds a single long-lived `IccDeviceCoordinator` that owns the
/// `ICDeviceBrowser` and any currently-open `ICCameraDevice` session.
public class IccPtpPlugin: NSObject, FlutterPlugin {
  private let coordinator: IccDeviceCoordinator

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
    // Phase B/C — will call coordinator.openSession(deviceId:completion:).
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "openSession lands in Phase C",
      details: nil
    )))
  }

  func sendCommand(
    command: PtpCommand,
    completion: @escaping (Result<PtpCommandResult, Error>) -> Void
  ) {
    // Phase C — will marshal command to ICCameraDevice.requestSendPTPCommand.
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "sendCommand lands in Phase C",
      details: nil
    )))
  }

  func closeSession(completion: @escaping (Result<Void, Error>) -> Void) {
    // Phase C — will call coordinator.closeSession(...).
    completion(.success(()))
  }
}
