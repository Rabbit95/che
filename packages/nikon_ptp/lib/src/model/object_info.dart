import 'package:meta/meta.dart';

@immutable
final class ObjectInfo {
  const ObjectInfo({
    required this.storageId,
    required this.objectFormat,
    required this.protectionStatus,
    required this.objectCompressedSize,
    required this.thumbFormat,
    required this.thumbCompressedSize,
    required this.thumbPixWidth,
    required this.thumbPixHeight,
    required this.imagePixWidth,
    required this.imagePixHeight,
    required this.imageBitDepth,
    required this.parentObject,
    required this.associationType,
    required this.associationDesc,
    required this.sequenceNumber,
    required this.filename,
    required this.captureDate,
    required this.modificationDate,
    required this.keywords,
  });

  final int storageId;
  final int objectFormat;
  final int protectionStatus;
  final int objectCompressedSize;
  final int thumbFormat;
  final int thumbCompressedSize;
  final int thumbPixWidth;
  final int thumbPixHeight;
  final int imagePixWidth;
  final int imagePixHeight;
  final int imageBitDepth;
  final int parentObject;
  final int associationType;
  final int associationDesc;
  final int sequenceNumber;
  final String filename;
  final String captureDate;
  final String modificationDate;
  final String keywords;

  bool get isVideo => objectFormat == 0xB984 || objectFormat == 0x300D;
  bool get isRaw => objectFormat == 0xB101 || objectFormat == 0x3800;
  bool get isJpeg => objectFormat == 0x3801;
}
