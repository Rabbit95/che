import 'package:meta/meta.dart';

/// Parsed `GetDeviceInfo` (0x1001) response.
@immutable
final class DeviceInfo {
  const DeviceInfo({
    required this.standardVersion,
    required this.vendorExtensionId,
    required this.vendorExtensionVersion,
    required this.vendorExtensionDesc,
    required this.functionalMode,
    required this.operationsSupported,
    required this.eventsSupported,
    required this.devicePropertiesSupported,
    required this.captureFormats,
    required this.imageFormats,
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    required this.serialNumber,
  });

  final int standardVersion;
  final int vendorExtensionId;
  final int vendorExtensionVersion;
  final String vendorExtensionDesc;
  final int functionalMode;
  final List<int> operationsSupported;
  final List<int> eventsSupported;
  final List<int> devicePropertiesSupported;
  final List<int> captureFormats;
  final List<int> imageFormats;
  final String manufacturer;
  final String model;
  final String deviceVersion;
  final String serialNumber;

  bool supportsOperation(int opcode) => operationsSupported.contains(opcode);
  bool supportsEvent(int code) => eventsSupported.contains(code);
  bool supportsProperty(int code) => devicePropertiesSupported.contains(code);
}
