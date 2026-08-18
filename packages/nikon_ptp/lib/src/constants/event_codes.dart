/// Nikon vendor event codes (subset used by this project).
abstract final class NikonEventCode {
  NikonEventCode._();

  static const int objectAddedInSdram = 0xC101;
  static const int captureCompleteRecInSdram = 0xC102;
  static const int previewImageAdded = 0xC104;
  static const int movieRecordInterrupted = 0xC105;
  static const int movieRecordComplete = 0xC108;
  static const int movieRecordStarted = 0xC10A;
  static const int liveViewStateChanged = 0xC10C;
}

/// Standard PTP event codes (ISO 15740 §12).
abstract final class StandardEventCode {
  StandardEventCode._();

  static const int undefined = 0x4000;
  static const int cancelTransaction = 0x4001;
  static const int objectAdded = 0x4002;
  static const int objectRemoved = 0x4003;
  static const int storeAdded = 0x4004;
  static const int storeRemoved = 0x4005;
  static const int devicePropChanged = 0x4006;
  static const int objectInfoChanged = 0x4007;
  static const int deviceInfoChanged = 0x4008;
  static const int requestObjectTransfer = 0x4009;
  static const int storeFull = 0x400A;
  static const int deviceReset = 0x400B;
  static const int storageInfoChanged = 0x400C;
  static const int captureComplete = 0x400D;
  static const int unreportedStatus = 0x400E;
}
