import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

/// Builds a synthetic 384-byte header + tiny JPEG payload for tests.
/// Optional [afRect] and [imageSize] are written into the LV header at the
/// known Z6/Z6II/Z7/Z8/Z9 offsets so we can verify the parser.
Uint8List _buildBlob({
  Uint8List? header,
  ({int w, int h})? imageSize,
  ({int x, int y, int w, int h})? afRect,
  ({int x, int y, int w, int h})? focusArea,
  Uint8List? jpeg,
}) {
  final headerBytes = header ?? Uint8List(384);
  final view = ByteData.sublistView(headerBytes);
  if (imageSize != null) {
    view.setUint16(0x00, imageSize.w, Endian.little);
    view.setUint16(0x02, imageSize.h, Endian.little);
  }
  if (afRect != null) {
    view.setUint16(0x10, afRect.x, Endian.little);
    view.setUint16(0x12, afRect.y, Endian.little);
    view.setUint16(0x14, afRect.w, Endian.little);
    view.setUint16(0x16, afRect.h, Endian.little);
  }
  if (focusArea != null) {
    view.setUint16(0x18, focusArea.x, Endian.little);
    view.setUint16(0x1A, focusArea.y, Endian.little);
    view.setUint16(0x1C, focusArea.w, Endian.little);
    view.setUint16(0x1E, focusArea.h, Endian.little);
  }
  final payload = jpeg ??
      Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xD9]);
  final out = BytesBuilder()
    ..add(headerBytes)
    ..add(payload);
  return out.toBytes();
}

void main() {
  group('LiveViewFrameCodec.decode', () {
    test('splits header + JPEG at SOI marker', () {
      final blob = _buildBlob(imageSize: (w: 1280, h: 720));
      final frame = LiveViewFrameCodec.decode(blob);
      expect(frame, isNotNull);
      expect(frame!.jpeg.length, 6);
      expect(frame.jpeg[0], 0xFF);
      expect(frame.jpeg[1], 0xD8);
      expect(frame.header.imageWidth, 1280);
      expect(frame.header.imageHeight, 720);
    });

    test('returns null when SOI is missing', () {
      // Header-only, no JPEG at all — camera answered before LV came up.
      final headerOnly = Uint8List(384);
      final frame = LiveViewFrameCodec.decode(headerOnly);
      expect(frame, isNull);
    });

    test('returns null for empty blob', () {
      expect(LiveViewFrameCodec.decode(Uint8List(0)), isNull);
    });

    test('parses AF rect at documented offset', () {
      final blob = _buildBlob(
        imageSize: (w: 1920, h: 1080),
        afRect: (x: 640, y: 320, w: 200, h: 200),
      );
      final frame = LiveViewFrameCodec.decode(blob)!;
      expect(frame.header.afRect, isNotNull);
      expect(frame.header.afRect!.x, 640);
      expect(frame.header.afRect!.y, 320);
      expect(frame.header.afRect!.width, 200);
      expect(frame.header.afRect!.height, 200);
    });

    test('parses focus area at documented offset', () {
      final blob = _buildBlob(
        focusArea: (x: 100, y: 150, w: 40, h: 40),
      );
      final frame = LiveViewFrameCodec.decode(blob)!;
      expect(frame.header.focusArea, isNotNull);
      expect(frame.header.focusArea!.x, 100);
      expect(frame.header.focusArea!.width, 40);
    });

    test('null rects when width/height are zero (no AF lock)', () {
      final blob = _buildBlob(imageSize: (w: 1280, h: 720));
      final frame = LiveViewFrameCodec.decode(blob)!;
      expect(frame.header.afRect, isNull);
      expect(frame.header.focusArea, isNull);
    });

    test('handles short truncated header without crashing', () {
      // Only 4 bytes of "header" then straight to the JPEG. Parser must
      // stay in bounds and return whatever it can.
      final blob = Uint8List.fromList([
        0x00, 0x05, 0x00, 0x00, // width=1280
        0xFF, 0xD8, 0xFF, 0xD9,
      ]);
      final frame = LiveViewFrameCodec.decode(blob)!;
      expect(frame.jpeg.length, 4);
      expect(frame.header.imageWidth, 1280);
      expect(frame.header.afRect, isNull);
    });

    test('timestamp defaults to now when caller omits one', () {
      final before = DateTime.timestamp();
      final blob = _buildBlob();
      final frame = LiveViewFrameCodec.decode(blob)!;
      final after = DateTime.timestamp();
      expect(
        frame.timestamp.isAfter(before.subtract(const Duration(seconds: 1))) &&
            frame.timestamp
                .isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('timestamp honours explicit override', () {
      final fixed = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final blob = _buildBlob();
      final frame = LiveViewFrameCodec.decode(blob, timestamp: fixed)!;
      expect(frame.timestamp, fixed);
    });

    test('SOI hunt skips past leading FF bytes that are not FF D8', () {
      // JPEG SOI is the marker to lock onto — earlier `FF xx` sequences
      // that are not `FF D8` must not confuse the search.
      final blob = Uint8List.fromList([
        0xFF, 0x00, 0xFF, 0x01, 0xFF, 0xD8, 0xFF, 0xD9,
      ]);
      final frame = LiveViewFrameCodec.decode(blob)!;
      expect(frame.jpeg.length, 4);
      expect(frame.jpeg[0], 0xFF);
      expect(frame.jpeg[1], 0xD8);
    });
  });
}
