import 'dart:typed_data';

import '../constants/prop_codes.dart';
import '../errors/ptp_errors.dart';
import '../model/device_info.dart';
import '../model/device_prop_desc.dart';
import '../model/object_info.dart';
import '../model/storage_info.dart';
import 'byte_reader.dart';
import 'byte_writer.dart';

/// Parses PTP data-in payloads and serialises data-out payloads.
///
/// These structures are defined by ISO 15740 §5 and are shared across
/// every PTP transport (IP / USB / ICC).
abstract final class PtpDataCodec {
  PtpDataCodec._();

  static DeviceInfo readDeviceInfo(Uint8List data) {
    final r = ByteReader(data);
    return DeviceInfo(
      standardVersion: r.readU16(),
      vendorExtensionId: r.readU32(),
      vendorExtensionVersion: r.readU16(),
      vendorExtensionDesc: r.readPtpString(),
      functionalMode: r.readU16(),
      operationsSupported: r.readUint16Array(),
      eventsSupported: r.readUint16Array(),
      devicePropertiesSupported: r.readUint16Array(),
      captureFormats: r.readUint16Array(),
      imageFormats: r.readUint16Array(),
      manufacturer: r.readPtpString(),
      model: r.readPtpString(),
      deviceVersion: r.readPtpString(),
      serialNumber: r.readPtpString(),
    );
  }

  static StorageInfo readStorageInfo(int id, Uint8List data) {
    final r = ByteReader(data);
    return StorageInfo(
      id: id,
      storageType: r.readU16(),
      filesystemType: r.readU16(),
      accessCapability: r.readU16(),
      maxCapacity: r.readU64(),
      freeSpaceInBytes: r.readU64(),
      freeSpaceInImages: r.readU32(),
      description: r.readPtpString(),
      volumeLabel: r.readPtpString(),
    );
  }

  static ObjectInfo readObjectInfo(Uint8List data) {
    final r = ByteReader(data);
    return ObjectInfo(
      storageId: r.readU32(),
      objectFormat: r.readU16(),
      protectionStatus: r.readU16(),
      objectCompressedSize: r.readU32(),
      thumbFormat: r.readU16(),
      thumbCompressedSize: r.readU32(),
      thumbPixWidth: r.readU32(),
      thumbPixHeight: r.readU32(),
      imagePixWidth: r.readU32(),
      imagePixHeight: r.readU32(),
      imageBitDepth: r.readU32(),
      parentObject: r.readU32(),
      associationType: r.readU16(),
      associationDesc: r.readU32(),
      sequenceNumber: r.readU32(),
      filename: r.readPtpString(),
      captureDate: r.readPtpString(),
      modificationDate: r.readPtpString(),
      keywords: r.readPtpString(),
    );
  }

  static DevicePropDesc readDevicePropDesc(Uint8List data) {
    final r = ByteReader(data);
    final propCode = r.readU16();
    final dataType = r.readU16();
    final getSet = r.readU8();
    final defaultValue = _readTypedValue(r, dataType);
    final currentValue = _readTypedValue(r, dataType);
    final formFlag = r.readU8();

    final form = switch (formFlag) {
      PtpFormFlag.none => const NoForm(),
      PtpFormFlag.range => RangeForm(
          min: _readTypedValue(r, dataType) ?? 0,
          max: _readTypedValue(r, dataType) ?? 0,
          step: _readTypedValue(r, dataType) ?? 0,
        ),
      PtpFormFlag.enumeration => EnumForm(
          values: List<Object>.generate(
            r.readU16(),
            (_) => _readTypedValue(r, dataType) ?? 0,
          ),
        ),
      _ => throw PtpProtocolException('unknown form flag $formFlag'),
    };

    return DevicePropDesc(
      propCode: propCode,
      dataType: dataType,
      getSet: getSet,
      factoryDefault: defaultValue,
      currentValue: currentValue,
      form: form,
    );
  }

  /// Serialise a single value of the given [dataType] — used for
  /// SetDevicePropValue data-out.
  static Uint8List writeTypedValue(int dataType, Object value) {
    final w = ByteWriter();
    _writeTypedValue(w, dataType, value);
    return w.takeBytes();
  }

  static Object? _readTypedValue(ByteReader r, int dataType) {
    switch (dataType) {
      case PtpDataType.int8:
        return r.readI8();
      case PtpDataType.uint8:
        return r.readU8();
      case PtpDataType.int16:
        return r.readI16();
      case PtpDataType.uint16:
        return r.readU16();
      case PtpDataType.int32:
        return r.readI32();
      case PtpDataType.uint32:
        return r.readU32();
      case PtpDataType.int64:
        return r.readI64();
      case PtpDataType.uint64:
        return r.readU64();
      case PtpDataType.string:
        return r.readPtpString();
      case PtpDataType.aint8:
      case PtpDataType.auint8:
      case PtpDataType.aint16:
      case PtpDataType.auint16:
      case PtpDataType.aint32:
      case PtpDataType.auint32:
      case PtpDataType.aint64:
      case PtpDataType.auint64:
        final elementType = dataType & 0x00FF;
        final count = r.readU32();
        return List<Object>.generate(
          count,
          (_) => _readTypedValue(r, elementType) ?? 0,
        );
      case PtpDataType.undefined:
        return null;
      default:
        throw PtpProtocolException(
          'unsupported data type 0x${dataType.toRadixString(16)}',
        );
    }
  }

  static void _writeTypedValue(ByteWriter w, int dataType, Object value) {
    switch (dataType) {
      case PtpDataType.int8:
        w.writeI8(value as int);
      case PtpDataType.uint8:
        w.writeU8(value as int);
      case PtpDataType.int16:
        w.writeI16(value as int);
      case PtpDataType.uint16:
        w.writeU16(value as int);
      case PtpDataType.int32:
        w.writeI32(value as int);
      case PtpDataType.uint32:
        w.writeU32(value as int);
      case PtpDataType.int64:
        w.writeI64(value as int);
      case PtpDataType.uint64:
        w.writeU64(value as int);
      case PtpDataType.string:
        w.writePtpString(value as String);
      default:
        if (PtpDataType.isArray(dataType)) {
          final elementType = dataType & 0x00FF;
          final list = value as List<Object>;
          w.writeU32(list.length);
          for (final e in list) {
            _writeTypedValue(w, elementType, e);
          }
        } else {
          throw PtpProtocolException(
            'cannot serialise data type 0x${dataType.toRadixString(16)}',
          );
        }
    }
  }
}
