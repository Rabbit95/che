import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('ByteWriter → ByteReader round-trip', () {
    test('uint8/16/32/64 encode as little-endian', () {
      final w = ByteWriter()
        ..writeU8(0x12)
        ..writeU16(0x3456)
        ..writeU32(0x789ABCDE)
        ..writeU64(0x0123456789ABCDEF);
      final bytes = w.takeBytes();
      expect(
        bytes,
        equals(<int>[
          0x12,
          // 0x3456 LE
          0x56, 0x34,
          // 0x789ABCDE LE
          0xDE, 0xBC, 0x9A, 0x78,
          // 0x0123456789ABCDEF LE
          0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
        ]),
      );
    });

    test('signed values round-trip through their unsigned readers', () {
      final w = ByteWriter()
        ..writeI8(-1)
        ..writeI16(-2)
        ..writeI32(-3)
        ..writeI64(-4);
      final r = ByteReader(w.takeBytes());
      expect(r.readI8(), -1);
      expect(r.readI16(), -2);
      expect(r.readI32(), -3);
      expect(r.readI64(), -4);
    });

    test('PTP string: empty is a single zero byte', () {
      final w = ByteWriter()..writePtpString('');
      expect(w.takeBytes(), equals(<int>[0]));
    });

    test('PTP string encodes UTF-16LE with length + terminator', () {
      final w = ByteWriter()..writePtpString('Nikon');
      final bytes = w.takeBytes();
      // 5 chars + 1 terminator = 6 code units
      expect(bytes.first, 6);
      // Nikon = 4E 69 6B 6F 6E, each as LE uint16 (low, high=0)
      expect(bytes.sublist(1, 11), equals(<int>[
        0x4E, 0x00, 0x69, 0x00, 0x6B, 0x00, 0x6F, 0x00, 0x6E, 0x00,
      ]));
      // Terminator
      expect(bytes.sublist(11), equals(<int>[0x00, 0x00]));
    });

    test('PTP string round-trip with CJK codepoints', () {
      const s = '尼康 Z8 · 遥控';
      final w = ByteWriter()..writePtpString(s);
      final r = ByteReader(w.takeBytes());
      expect(r.readPtpString(), s);
    });

    test('UTF-16LE null-terminated round-trip', () {
      final w = ByteWriter()..writeUtf16LeNullTerminated('Nikon Z Control');
      final r = ByteReader(w.takeBytes());
      expect(r.readUtf16LeNullTerminated(), 'Nikon Z Control');
    });

    test('reader throws on underrun', () {
      final r = ByteReader(Uint8List.fromList(<int>[0x01, 0x02]));
      expect(() => r.readU32(), throwsA(isA<PtpProtocolException>()));
    });

    test('uint16 array round-trip', () {
      final w = ByteWriter()..writeUint16Array([0x1001, 0x1002, 0x9435]);
      final r = ByteReader(w.takeBytes());
      expect(r.readUint16Array(), [0x1001, 0x1002, 0x9435]);
    });
  });
}
