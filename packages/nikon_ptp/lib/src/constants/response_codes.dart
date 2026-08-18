/// Standard PTP response codes (ISO 15740 §11.3).
abstract final class PtpResponseCode {
  PtpResponseCode._();

  static const int undefined = 0x2000;
  static const int ok = 0x2001;
  static const int generalError = 0x2002;
  static const int sessionNotOpen = 0x2003;
  static const int invalidTransactionId = 0x2004;
  static const int operationNotSupported = 0x2005;
  static const int parameterNotSupported = 0x2006;
  static const int incompleteTransfer = 0x2007;
  static const int invalidStorageId = 0x2008;
  static const int invalidObjectHandle = 0x2009;
  static const int devicePropNotSupported = 0x200A;
  static const int invalidObjectFormatCode = 0x200B;
  static const int storeFull = 0x200C;
  static const int objectWriteProtected = 0x200D;
  static const int storeReadOnly = 0x200E;
  static const int accessDenied = 0x200F;
  static const int noThumbnailPresent = 0x2010;
  static const int selfTestFailed = 0x2011;
  static const int partialDeletion = 0x2012;
  static const int storeNotAvailable = 0x2013;
  static const int specificationByFormatUnsupported = 0x2014;
  static const int noValidObjectInfo = 0x2015;
  static const int invalidCodeFormat = 0x2016;
  static const int unknownVendorCode = 0x2017;
  static const int captureAlreadyTerminated = 0x2018;
  static const int deviceBusy = 0x2019;
  static const int invalidParentObject = 0x201A;
  static const int invalidDevicePropFormat = 0x201B;
  static const int invalidDevicePropValue = 0x201C;
  static const int invalidParameter = 0x201D;
  static const int sessionAlreadyOpen = 0x201E;
  static const int transactionCancelled = 0x201F;
  static const int specificationOfDestinationUnsupported = 0x2020;

  // Nikon vendor extensions
  static const int nikonHardwareError = 0xA001;
  static const int nikonOutOfFocus = 0xA002;
  static const int nikonChangeCameraModeFailed = 0xA003;
  static const int nikonInvalidStatus = 0xA004;
  static const int nikonSetPropertyNotSupported = 0xA005;
  static const int nikonWbResetError = 0xA006;
  static const int nikonBulbReleaseBusy = 0xA00C;
  static const int nikonShutterSpeedBulb = 0xA00D;
  static const int nikonAeAfLocked = 0xA00E;
  static const int nikonNoJpegPresent = 0xA00F;

  /// Returns true when the code indicates the command completed successfully.
  static bool isOk(int code) => code == ok;

  /// Human-readable label suitable for logging or error UI.
  static String label(int code) {
    switch (code) {
      case ok:
        return 'OK';
      case sessionNotOpen:
        return 'SessionNotOpen';
      case invalidTransactionId:
        return 'InvalidTransactionId';
      case operationNotSupported:
        return 'OperationNotSupported';
      case parameterNotSupported:
        return 'ParameterNotSupported';
      case accessDenied:
        return 'AccessDenied';
      case invalidStorageId:
        return 'InvalidStorageId';
      case invalidObjectHandle:
        return 'InvalidObjectHandle';
      case devicePropNotSupported:
        return 'DevicePropNotSupported';
      case storeFull:
        return 'StoreFull';
      case storeNotAvailable:
        return 'StoreNotAvailable';
      case deviceBusy:
        return 'DeviceBusy';
      case invalidDevicePropValue:
        return 'InvalidDevicePropValue';
      case sessionAlreadyOpen:
        return 'SessionAlreadyOpen';
      case transactionCancelled:
        return 'TransactionCancelled';
      case nikonHardwareError:
        return 'Nikon.HardwareError';
      case nikonOutOfFocus:
        return 'Nikon.OutOfFocus';
      case nikonChangeCameraModeFailed:
        return 'Nikon.ChangeCameraModeFailed';
      case nikonInvalidStatus:
        return 'Nikon.InvalidStatus';
      case nikonBulbReleaseBusy:
        return 'Nikon.BulbReleaseBusy';
      default:
        return '0x${code.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    }
  }
}
