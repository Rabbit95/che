/// Standard PTP operation codes (ISO 15740 §10) — the subset this project uses.
abstract final class StandardOpcode {
  StandardOpcode._();

  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002;
  static const int closeSession = 0x1003;
  static const int getStorageIds = 0x1004;
  static const int getStorageInfo = 0x1005;
  static const int getNumObjects = 0x1006;
  static const int getObjectHandles = 0x1007;
  static const int getObjectInfo = 0x1008;
  static const int getObject = 0x1009;
  static const int getThumb = 0x100A;
  static const int deleteObject = 0x100B;
  static const int initiateCapture = 0x100E;
  static const int formatStore = 0x100F;
  static const int getDevicePropDesc = 0x1014;
  static const int getDevicePropValue = 0x1015;
  static const int setDevicePropValue = 0x1016;
  static const int getPartialObject = 0x101B;
}
