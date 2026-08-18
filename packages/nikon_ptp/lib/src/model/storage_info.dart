import 'package:meta/meta.dart';

@immutable
final class StorageInfo {
  const StorageInfo({
    required this.id,
    required this.storageType,
    required this.filesystemType,
    required this.accessCapability,
    required this.maxCapacity,
    required this.freeSpaceInBytes,
    required this.freeSpaceInImages,
    required this.description,
    required this.volumeLabel,
  });

  final int id;
  final int storageType;
  final int filesystemType;
  final int accessCapability;
  final int maxCapacity;
  final int freeSpaceInBytes;
  final int freeSpaceInImages;
  final String description;
  final String volumeLabel;
}
