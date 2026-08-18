/// Standard PTP DeviceProperty codes (ISO 15740 §13.2).
abstract final class StandardPropCode {
  StandardPropCode._();

  static const int batteryLevel = 0x5001;
  static const int whiteBalance = 0x5005;
  static const int fNumber = 0x5007;
  static const int focalLength = 0x5008;
  static const int focusMode = 0x500A;
  static const int exposureMeteringMode = 0x500B;
  static const int flashMode = 0x500C;
  static const int exposureTime = 0x500D;
  static const int exposureProgramMode = 0x500E;
  static const int exposureIndex = 0x500F; // ISO
  static const int exposureBiasCompensation = 0x5010;
  static const int captureDelay = 0x5012;
  static const int stillCaptureMode = 0x5013;
  static const int focusDistance = 0x5017;
}

/// Nikon vendor DeviceProperty codes (subset — the full set is enumerated
/// at runtime via GetVendorPropCodes 0x90CA).
abstract final class NikonPropCode {
  NikonPropCode._();

  static const int liveViewStatus = 0xD1A2;
  static const int recordingMedia = 0xD10B;
  static const int liveViewImageZoomRatio = 0xD1A3;
  static const int exposureRemaining = 0xD121;
  static const int liveViewProhibitCondition = 0xD1A4;
  static const int movieRecordState = 0xD1B7;
  static const int externalRecordingControl = 0xD1B6;
}

/// PTP datatype codes used in property descriptors.
abstract final class PtpDataType {
  PtpDataType._();

  static const int undefined = 0x0000;
  static const int int8 = 0x0001;
  static const int uint8 = 0x0002;
  static const int int16 = 0x0003;
  static const int uint16 = 0x0004;
  static const int int32 = 0x0005;
  static const int uint32 = 0x0006;
  static const int int64 = 0x0007;
  static const int uint64 = 0x0008;
  static const int int128 = 0x0009;
  static const int uint128 = 0x000A;

  static const int aint8 = 0x4001;
  static const int auint8 = 0x4002;
  static const int aint16 = 0x4003;
  static const int auint16 = 0x4004;
  static const int aint32 = 0x4005;
  static const int auint32 = 0x4006;
  static const int aint64 = 0x4007;
  static const int auint64 = 0x4008;

  static const int string = 0xFFFF;

  static bool isArray(int type) => (type & 0x4000) != 0;
}

/// Property form-flag values.
abstract final class PtpFormFlag {
  PtpFormFlag._();

  static const int none = 0x00;
  static const int range = 0x01;
  static const int enumeration = 0x02;
}
