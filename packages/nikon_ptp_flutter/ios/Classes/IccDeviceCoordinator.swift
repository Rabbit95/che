import Foundation
import ImageCaptureCore

/// Owns the `ICDeviceBrowser` and the currently-active `ICCameraDevice`
/// session. Phase B — browser lifecycle + add/remove push callbacks are
/// live; Phase C fills in the PTP command marshalling.
final class IccDeviceCoordinator: NSObject {
  private let flutterApi: IccPtpFlutterApi
  private let browser: ICDeviceBrowser
  private var devicesById: [String: ICCameraDevice] = [:]

  init(flutterApi: IccPtpFlutterApi) {
    self.flutterApi = flutterApi
    self.browser = ICDeviceBrowser()
    super.init()

    self.browser.delegate = self
    // Cameras only, local (USB-C wired) location. `ICDeviceLocationType`
    // constants are OR'd into the same mask as the device-type bits.
    // Network cameras use PTP/IP directly and never go through ICA.
    let mask = ICDeviceTypeMask(rawValue:
      ICDeviceTypeMask.camera.rawValue |
      ICDeviceLocationTypeMask.local.rawValue
    )
    if let mask = mask {
      self.browser.browsedDeviceTypeMask = mask
    }
    self.browser.start()
  }

  deinit {
    browser.stop()
  }

  /// Snapshot of the current browser cache for `IccPtpHostApi.devices()`.
  ///
  /// Serial and isRemote stay null / false — they're macOS-only fields on
  /// `ICDevice`. On iOS the real body serial only becomes known once
  /// PTP GetDeviceInfo runs (Phase C).
  func snapshot() -> [IccCameraInfo] {
    return devicesById.map { (deviceId, device) in
      makeInfo(deviceId: deviceId, device: device)
    }
  }

  private func makeInfo(deviceId: String, device: ICCameraDevice)
    -> IccCameraInfo
  {
    return IccCameraInfo(
      deviceId: deviceId,
      name: device.name ?? "Unknown camera",
      transportKind: "usb",
      model: device.name,
      serialNumber: nil,
      isRemote: false
    )
  }

  /// Stable id for both browser-callback map keys and Dart-side references.
  /// `persistentIDString` is preferred (survives replug), falling back to
  /// an ephemeral UUID if the device somehow lacks one.
  private func idFor(_ device: ICDevice) -> String {
    if let pid = device.persistentIDString, !pid.isEmpty { return pid }
    return UUID().uuidString
  }
}

extension IccDeviceCoordinator: ICDeviceBrowserDelegate {
  func deviceBrowser(
    _ browser: ICDeviceBrowser,
    didAdd device: ICDevice,
    moreComing: Bool
  ) {
    guard let camera = device as? ICCameraDevice else { return }
    let deviceId = idFor(camera)
    devicesById[deviceId] = camera
    let info = makeInfo(deviceId: deviceId, device: camera)
    flutterApi.onDeviceAdded(device: info) { _ in }
  }

  func deviceBrowser(
    _ browser: ICDeviceBrowser,
    didRemove device: ICDevice,
    moreGoing: Bool
  ) {
    let deviceId = idFor(device)
    devicesById.removeValue(forKey: deviceId)
    flutterApi.onDeviceRemoved(deviceId: deviceId) { _ in }
    // Phase C: if this was the actively-open session's device, also emit
    // `onSessionEnded(reason: "unplug")` here.
  }
}
