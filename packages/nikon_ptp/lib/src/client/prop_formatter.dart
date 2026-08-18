import '../constants/prop_codes.dart';

/// Human-readable formatting for PTP device properties.
///
/// Formulas come from ISO 15740 §13.2 for the standard props (ISO, shutter,
/// aperture, EV, white balance, focus mode, exposure program) and from the
/// libgphoto2 `camlibs/ptp2/config.c` lookup tables for Nikon vendor enums.
///
/// Kept pure-Dart (no Flutter deps) so it can be unit-tested in isolation
/// and reused from any transport.
abstract final class PropFormatter {
  PropFormatter._();

  /// Short label used in the exposure strip pill (e.g. "ISO", "SHUTTER").
  static String labelFor(int propCode) {
    switch (propCode) {
      case StandardPropCode.exposureIndex:
        return 'ISO';
      case StandardPropCode.exposureTime:
        return 'SHUTTER';
      case StandardPropCode.fNumber:
        return 'APERTURE';
      case StandardPropCode.exposureBiasCompensation:
        return 'EV';
      case StandardPropCode.whiteBalance:
        return 'WB';
      case StandardPropCode.focusMode:
        return 'FOCUS';
      case StandardPropCode.exposureProgramMode:
        return 'MODE';
      case StandardPropCode.batteryLevel:
        return 'BATT';
      case StandardPropCode.focalLength:
        return 'FOCAL';
      case StandardPropCode.flashMode:
        return 'FLASH';
      case StandardPropCode.exposureMeteringMode:
        return 'METER';
      case StandardPropCode.stillCaptureMode:
        return 'DRIVE';
      default:
        return _hex4(propCode);
    }
  }

  /// Long, user-facing name used in the parameter sheet rows.
  static String longNameFor(int propCode) {
    switch (propCode) {
      case StandardPropCode.exposureIndex:
        return 'ISO';
      case StandardPropCode.exposureTime:
        return '快门';
      case StandardPropCode.fNumber:
        return '光圈';
      case StandardPropCode.exposureBiasCompensation:
        return '曝光补偿';
      case StandardPropCode.whiteBalance:
        return '白平衡';
      case StandardPropCode.focusMode:
        return '对焦模式';
      case StandardPropCode.exposureProgramMode:
        return '曝光模式';
      case StandardPropCode.batteryLevel:
        return '电量';
      case StandardPropCode.focalLength:
        return '焦距';
      case StandardPropCode.flashMode:
        return '闪光灯';
      case StandardPropCode.exposureMeteringMode:
        return '测光模式';
      case StandardPropCode.stillCaptureMode:
        return '驱动模式';
      default:
        return 'Prop ${_hex4(propCode)}';
    }
  }

  /// Format a property's current value for display. Falls back to a hex
  /// dump of the raw integer if we don't have a formula for the prop.
  ///
  /// [value] is what [PtpDataCodec] decoded — usually an `int`, a `String`,
  /// or (for array-typed props) a `List`.
  static String formatValue(int propCode, Object? value) {
    if (value == null) return '—';
    switch (propCode) {
      case StandardPropCode.exposureIndex:
        return _formatIso(value);
      case StandardPropCode.exposureTime:
        return _formatShutter(value);
      case StandardPropCode.fNumber:
        return _formatAperture(value);
      case StandardPropCode.exposureBiasCompensation:
        return _formatExposureBias(value);
      case StandardPropCode.whiteBalance:
        return _formatWhiteBalance(value);
      case StandardPropCode.focusMode:
        return _formatFocusMode(value);
      case StandardPropCode.exposureProgramMode:
        return _formatExposureProgram(value);
      case StandardPropCode.batteryLevel:
        return _formatBattery(value);
      case StandardPropCode.focalLength:
        return _formatFocalLength(value);
      case StandardPropCode.flashMode:
        return _formatFlashMode(value);
      case StandardPropCode.exposureMeteringMode:
        return _formatMeteringMode(value);
      case StandardPropCode.stillCaptureMode:
        return _formatStillCaptureMode(value);
      default:
        if (value is int) return value.toString();
        if (value is String) return value;
        return value.toString();
    }
  }

  // ─── formatters ─────────────────────────────────────────────────

  static String _formatIso(Object value) {
    if (value is! int) return value.toString();
    // Nikon uses 0xFFFFFFFF (or 0xFFFF for uint16 props) as "Auto ISO".
    if (value == 0xFFFF || value == 0xFFFFFFFF) return 'AUTO';
    return value.toString();
  }

  /// PTP shutter time is a UInt32 in units of 0.0001 s (10⁻⁴ s).
  /// Special values:
  ///   0x00000000 → Bulb
  ///   0xFFFFFFFF → Time / not-set
  static String _formatShutter(Object value) {
    if (value is! int) return value.toString();
    if (value == 0) return 'BULB';
    if (value == 0xFFFFFFFF) return 'TIME';
    // Convert 0.1ms units → seconds.
    // Fast shutters: express as 1/N with N rounded to standard fraction.
    if (value < 10000) {
      final n = (10000 / value).round();
      return '1/$n';
    }
    // Longer than 1s: express as seconds with 1 decimal when needed.
    final seconds = value / 10000.0;
    if (seconds == seconds.roundToDouble()) {
      return '${seconds.toInt()}"';
    }
    return '${seconds.toStringAsFixed(1)}"';
  }

  /// PTP f-number is UInt16 in hundredths (280 → f/2.8).
  static String _formatAperture(Object value) {
    if (value is! int) return value.toString();
    final f = value / 100.0;
    // 1 decimal place for f/1.4 style, whole numbers for f/8 / f/16.
    if (f == f.roundToDouble()) {
      return 'f/${f.toInt()}';
    }
    return 'f/${f.toStringAsFixed(1)}';
  }

  /// PTP exposure bias compensation is Int16 in units of 0.001 EV.
  /// Nikon exposes values like ±5000 with 333/1000 step → ±5 EV in 1/3 stops.
  static String _formatExposureBias(Object value) {
    if (value is! int) return value.toString();
    if (value == 0) return '0.0';
    final ev = value / 1000.0;
    final sign = ev >= 0 ? '+' : '−';
    return '$sign${ev.abs().toStringAsFixed(1)}';
  }

  /// White balance enum (ISO 15740 §13.2.13).
  static String _formatWhiteBalance(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return 'MANUAL';
      case 0x0002:
        return 'AUTO';
      case 0x0003:
        return 'ONE-PUSH';
      case 0x0004:
        return 'DAYLIGHT';
      case 0x0005:
        return 'FLUOR';
      case 0x0006:
        return 'TUNGSTEN';
      case 0x0007:
        return 'FLASH';
      // Nikon vendor
      case 0x8010:
        return 'CLOUDY';
      case 0x8011:
        return 'SHADE';
      case 0x8012:
        return 'COLORTEMP';
      case 0x8013:
        return 'PRESET';
      case 0x8014:
        return 'NATURAL';
      default:
        return _hex4(value);
    }
  }

  static String _formatFocusMode(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return 'MF';
      case 0x0002:
        return 'AF-S';
      case 0x0003:
        return 'AF-C · 单点';
      // Nikon vendor
      case 0x8010:
        return 'AF-C';
      case 0x8011:
        return 'AF-A';
      case 0x8012:
        return 'M';
      case 0x8013:
        return 'AF-F';
      default:
        return _hex4(value);
    }
  }

  static String _formatExposureProgram(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return 'M';
      case 0x0002:
        return 'AUTO';
      case 0x0003:
        return 'A';
      case 0x0004:
        return 'S';
      case 0x0005:
        return 'P';
      // Nikon vendor
      case 0x8010:
        return 'AUTO';
      case 0x8011:
        return 'PORTRAIT';
      case 0x8012:
        return 'LANDSCAPE';
      case 0x8013:
        return 'CLOSE-UP';
      case 0x8014:
        return 'SPORTS';
      case 0x8015:
        return 'NIGHT';
      case 0x8050:
        return 'U1';
      case 0x8051:
        return 'U2';
      case 0x8052:
        return 'U3';
      default:
        return _hex4(value);
    }
  }

  static String _formatBattery(Object value) {
    if (value is! int) return value.toString();
    return '$value%';
  }

  /// PTP focal length is UInt32 in units of 0.01 mm (2400 → 24 mm).
  static String _formatFocalLength(Object value) {
    if (value is! int) return value.toString();
    final mm = value / 100.0;
    if (mm == mm.roundToDouble()) return '${mm.toInt()}mm';
    return '${mm.toStringAsFixed(1)}mm';
  }

  static String _formatFlashMode(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return 'AUTO';
      case 0x0002:
        return 'OFF';
      case 0x0003:
        return 'FILL';
      case 0x0004:
        return 'RED-EYE AUTO';
      case 0x0005:
        return 'RED-EYE FILL';
      case 0x0006:
        return 'EXTERNAL SYNC';
      default:
        return _hex4(value);
    }
  }

  static String _formatMeteringMode(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return 'AVERAGE';
      case 0x0002:
        return 'CENTER-W';
      case 0x0003:
        return 'MULTI';
      case 0x0004:
        return 'SPOT';
      case 0x8010:
        return 'HIGHLIGHT';
      default:
        return _hex4(value);
    }
  }

  static String _formatStillCaptureMode(Object value) {
    if (value is! int) return value.toString();
    switch (value) {
      case 0x0001:
        return '单张';
      case 0x0002:
        return '连拍';
      case 0x0003:
        return '定时';
      case 0x8010:
        return '连拍 H';
      case 0x8011:
        return '连拍 L';
      case 0x8012:
        return '定时 · 遥控';
      case 0x8013:
        return '静音';
      case 0x8014:
        return '静音连拍';
      case 0x8015:
        return '包围';
      default:
        return _hex4(value);
    }
  }

  static String _hex4(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

/// The core props the parameter sheet + exposure bar surface at connect
/// time. Ordered by editorial priority — ISO first, drive-mode last.
const List<int> kCorePropCodes = <int>[
  StandardPropCode.exposureIndex,
  StandardPropCode.exposureTime,
  StandardPropCode.fNumber,
  StandardPropCode.exposureBiasCompensation,
  StandardPropCode.whiteBalance,
  StandardPropCode.focusMode,
  StandardPropCode.exposureProgramMode,
  StandardPropCode.stillCaptureMode,
  StandardPropCode.batteryLevel,
];
