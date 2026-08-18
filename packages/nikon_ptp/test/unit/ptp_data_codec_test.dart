import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('PtpDataCodec.readDeviceInfo', () {
    test('parses a minimal but valid GetDeviceInfo payload', () {
      // Construct a legit payload with the ByteWriter, then read it back.
      final w = ByteWriter()
        ..writeU16(100) // standard version
        ..writeU32(0x0000000A) // Nikon vendor extension id
        ..writeU16(100)
        ..writePtpString('nikon')
        ..writeU16(0) // functional mode
        ..writeUint16Array([0x1001, 0x1002, 0x9435])
        ..writeUint16Array([0xC101])
        ..writeUint16Array([0x5001, 0x500F])
        ..writeUint16Array([0x3801])
        ..writeUint16Array([0x3801, 0xB101])
        ..writePtpString('Nikon Corporation')
        ..writePtpString('Nikon Z8')
        ..writePtpString('v3.00')
        ..writePtpString('6001234');
      final info = PtpDataCodec.readDeviceInfo(w.takeBytes());
      expect(info.model, 'Nikon Z8');
      expect(info.manufacturer, 'Nikon Corporation');
      expect(info.serialNumber, '6001234');
      expect(info.supportsOperation(0x9435), isTrue);
      expect(info.supportsProperty(0x500F), isTrue);
      expect(info.supportsEvent(0xC101), isTrue);
      expect(info.imageFormats, contains(0xB101));
    });
  });

  group('PtpDataCodec.readDevicePropDesc', () {
    test('range-form uint16 property (e.g. shutter speed 1/8000..30s idx)',
        () {
      final w = ByteWriter()
        ..writeU16(0x5007) // propCode
        ..writeU16(0x0004) // uint16
        ..writeU8(0x01) // get/set
        ..writeU16(28) // factory default (aperture idx)
        ..writeU16(28) // current value
        ..writeU8(0x01) // range form
        ..writeU16(14) // min
        ..writeU16(64) // max
        ..writeU16(2); // step
      final desc = PtpDataCodec.readDevicePropDesc(w.takeBytes());
      expect(desc.propCode, 0x5007);
      expect(desc.isWritable, isTrue);
      expect(desc.form, isA<RangeForm>());
      final range = desc.form as RangeForm;
      expect(range.min, 14);
      expect(range.max, 64);
      expect(range.step, 2);
    });

    test('enum-form uint32 (e.g. white balance modes)', () {
      final w = ByteWriter()
        ..writeU16(0x5005) // WB
        ..writeU16(0x0006) // uint32
        ..writeU8(0x01)
        ..writeU32(0x02)
        ..writeU32(0x04)
        ..writeU8(0x02) // enum form
        ..writeU16(4)
        ..writeU32(0x02)
        ..writeU32(0x03)
        ..writeU32(0x04)
        ..writeU32(0x05);
      final desc = PtpDataCodec.readDevicePropDesc(w.takeBytes());
      expect(desc.form, isA<EnumForm>());
      final e = desc.form as EnumForm;
      expect(e.values, [0x02, 0x03, 0x04, 0x05]);
    });
  });

  group('PtpDataCodec.readObjectInfo', () {
    test('parses filename + size', () {
      final w = ByteWriter()
        ..writeU32(0x00010001) // storage id
        ..writeU16(0xB101) // NEF
        ..writeU16(0)
        ..writeU32(42600000) // compressed size
        ..writeU16(0)
        ..writeU32(0)
        ..writeU32(0)
        ..writeU32(0)
        ..writeU32(8256)
        ..writeU32(5504)
        ..writeU32(14)
        ..writeU32(0)
        ..writeU16(0)
        ..writeU32(0)
        ..writeU32(2841)
        ..writePtpString('DSC_2841.NEF')
        ..writePtpString('20260817T144231')
        ..writePtpString('')
        ..writePtpString('');
      final info = PtpDataCodec.readObjectInfo(w.takeBytes());
      expect(info.filename, 'DSC_2841.NEF');
      expect(info.objectCompressedSize, 42600000);
      expect(info.isRaw, isTrue);
      expect(info.imagePixWidth, 8256);
    });
  });

  group('PtpDataCodec.writeTypedValue', () {
    test('int8/uint16/uint32 round-trip', () {
      final b1 = PtpDataCodec.writeTypedValue(0x0002, 0xFE); // uint8
      expect(b1, [0xFE]);
      final b2 = PtpDataCodec.writeTypedValue(0x0004, 0x1234); // uint16
      expect(b2, [0x34, 0x12]);
      final b3 = PtpDataCodec.writeTypedValue(0x0006, 0xDEADBEEF); // uint32
      expect(b3, [0xEF, 0xBE, 0xAD, 0xDE]);
    });

    test('string emits PTP-string layout', () {
      final b = PtpDataCodec.writeTypedValue(0xFFFF, 'abc');
      // 4 code units (a b c \0) → length byte 4, then LE UTF-16 chars.
      expect(b, [4, 0x61, 0x00, 0x62, 0x00, 0x63, 0x00, 0x00, 0x00]);
    });
  });
}
