import Foundation
import ImageCaptureCore

/// Owns the `ICDeviceBrowser` and the currently-active `ICCameraDevice`
/// session. Phase A stub — Phase B fills in the browser + delegate methods,
/// Phase C fills in the PTP command marshalling.
final class IccDeviceCoordinator: NSObject {
  private let flutterApi: IccPtpFlutterApi
  private var devicesById: [String: ICCameraDevice] = [:]

  init(flutterApi: IccPtpFlutterApi) {
    self.flutterApi = flutterApi
    super.init()
    // Phase B — start ICDeviceBrowser here.
  }

  /// Snapshot of the current browser cache for `IccPtpHostApi.devices()`.
  ///
  /// `ICDevice.serialNumberString` and `ICDevice.isRemote` are macOS-only;
  /// on iOS the serial only becomes known once PTP GetDeviceInfo runs, so
  /// we surface null / false here and let the higher layers fill them in
  /// after the session opens.
  func snapshot() -> [IccCameraInfo] {
    return devicesById.map { (deviceId, device) in
      IccCameraInfo(
        deviceId: deviceId,
        name: device.name ?? "Unknown camera",
        transportKind: transportKind(for: device),
        model: device.name,
        serialNumber: nil,
        isRemote: false
      )
    }
  }

  private func transportKind(for device: ICCameraDevice) -> String {
    let type = device.transportType ?? ""
    if type.contains("USB") { return "usb" }
    if type.contains("TCPIP") || type.contains("Bonjour") { return "network" }
    return "unknown"
  }
}
