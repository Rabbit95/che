/// Nikon vendor-extension operation codes used by the Z-series.
///
/// Reference: libgphoto2 `camlibs/ptp2/ptp.h`. Codes cross-checked
/// against the public NKN SDK header dumps and the ptplibrary project.
abstract final class NikonOpcode {
  NikonOpcode._();

  /// Must be the FIRST vendor command sent after OpenSession on Z bodies.
  /// Param0=1 puts the camera into "MobileApp / controller" mode.
  static const int changeApplicationMode = 0x9435;

  /// Poll after a state-changing command; returns 0x2019 (DeviceBusy) while
  /// the mechanism is still moving.
  static const int deviceReady = 0x90C8;

  /// Enumerate additional vendor property codes (returned as a UINT16 array).
  static const int getVendorPropCodes = 0x90CA;

  /// Z-series structured event polling (larger event record than 0x90C7).
  static const int getEventEx = 0x941C;

  /// Legacy event polling (still supported by older Zs as fallback).
  static const int getEvent = 0x90C7;

  // Live View
  static const int startLiveView = 0x9201;
  static const int endLiveView = 0x9202;

  /// Legacy Live View frame (used by Z50 / Zfc / older firmware).
  static const int getLiveViewImg = 0x9203;

  /// Preferred Live View frame accessor for modern Z bodies.
  /// Returns a Nikon LV blob: 384-byte header + JPEG.
  static const int getLiveViewImageEx = 0x9428;

  // Focus / capture
  static const int mfDrive = 0x9204;
  static const int changeAfArea = 0x9205;
  static const int afDriveCancel = 0x9206;
  static const int afDrive = 0x90C1;
  static const int initiateCaptureRecInMedia = 0x9207;
  static const int afAndCaptureRecInSdram = 0x90CB;

  // Movie
  static const int startMovieRecInCard = 0x920A;
  static const int endMovieRec = 0x920B;

  /// Cancel a rolling capture (bulb / continuous / video).
  static const int terminateCapture = 0x920C;

  // Object / storage
  static const int getObjectSize = 0x9421;
  static const int getPartialObjectEx = 0x9431; // 64-bit offset/length
  static const int getObjectsMetaData = 0x9434;

  // Subject tracking / AE lock
  static const int startTracking = 0x9424;
  static const int endTracking = 0x9425;
  static const int changeAeLock = 0x9426;
}
