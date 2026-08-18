/// Nikon USB vendor / product IDs for the Z-series bodies this app targets.
///
/// Sourced from libgphoto2 `camlibs/ptp2/library.c` + Nikon's own device
/// enumeration. IDs verified against actual bodies where possible; entries
/// with a `?` in the comment need confirmation against a real device.
abstract final class NikonUsbIds {
  NikonUsbIds._();

  /// Nikon Corp. — vendor id shared by every Nikon camera on USB.
  static const int vendorId = 0x04B0;

  /// Map of USB Product ID → marketing model name. Includes both the
  /// "PTP mode" PID (what a Z body exposes when set to MTP/PTP) and, where
  /// known, the WMR / iPhone mode PID.
  static const Map<int, String> productIds = <int, String>{
    // Z series (PTP mode PIDs)
    0x0442: 'Nikon Z 7',
    0x0443: 'Nikon Z 6',
    0x0444: 'Nikon Z 50',
    0x0445: 'Nikon Z 5',
    0x0446: 'Nikon Z 7II',
    0x0447: 'Nikon Z 6II',
    0x0448: 'Nikon Z fc',
    0x044B: 'Nikon Z 9',
    0x044C: 'Nikon Z 30',
    0x044D: 'Nikon Z 8',
    0x044E: 'Nikon Z f',
    0x044F: 'Nikon Z 6III',
    0x0451: 'Nikon Z 50II',
  };

  static String? modelFor(int pid) => productIds[pid];

  static bool isNikon(int vid) => vid == vendorId;
  static bool isKnownZ(int vid, int pid) =>
      vid == vendorId && productIds.containsKey(pid);
}
