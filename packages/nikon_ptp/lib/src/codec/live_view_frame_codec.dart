import 'dart:typed_data';

import '../model/live_view_frame.dart';

/// Decoder for the raw payload returned by `GetLiveViewImageEx` (0x9428)
/// on modern Nikon Z bodies and by `GetLiveViewImg` (0x9203) on the older
/// legacy path.
///
/// The blob is a Nikon-specific header (typically ~384 bytes on Z6/Z7/Z8/Z9,
/// larger on some firmware) followed by a JPEG. Field layout inside the
/// header varies by model and firmware, so this decoder:
///
///  1. Splits header + JPEG on the JPEG SOI marker (`FF D8`), which is
///     stable everywhere.
///  2. Best-effort parses a small set of fields we know are consistent
///     across the Z line (image dimensions, AF box, exposure hints).
///
/// Any field we can't confidently read is left null; consumers must
/// tolerate an [LvHeader] with mostly-null fields.
abstract final class LiveViewFrameCodec {
  LiveViewFrameCodec._();

  static const int _soiFirst = 0xFF;
  static const int _soiSecond = 0xD8;

  /// Decode a raw Live View blob into a [LiveViewFrame].
  ///
  /// Returns `null` if [raw] doesn't contain a JPEG SOI marker — that's
  /// the camera answering "no frame yet" (LV disabled, warming up, or
  /// swapping mode). Callers can treat it as a soft skip.
  static LiveViewFrame? decode(Uint8List raw, {DateTime? timestamp}) {
    if (raw.length < 4) return null;
    final soi = _findSoi(raw);
    if (soi < 0) return null;

    final headerBytes = Uint8List.sublistView(raw, 0, soi);
    final jpeg = Uint8List.sublistView(raw, soi);

    return LiveViewFrame(
      jpeg: jpeg,
      header: _parseHeader(headerBytes),
      timestamp: timestamp ?? DateTime.timestamp(),
    );
  }

  /// Locate the first `FF D8` pair — the JPEG SOI marker. Nikon LV blobs
  /// prepend a fixed-width header (never containing `FF D8`), so the
  /// first hit is always the real image start.
  static int _findSoi(Uint8List b) {
    for (var i = 0; i < b.length - 1; i++) {
      if (b[i] == _soiFirst && b[i + 1] == _soiSecond) return i;
    }
    return -1;
  }

  /// Best-effort parse of the Nikon LV header.
  ///
  /// The layout used here matches Z6 / Z6II / Z6III / Z7 / Z7II / Z8 / Z9
  /// per the libgphoto2 `ptp2/liveview.c` treatment:
  ///
  /// - `[0x00] u16` — LV frame width (pixels)
  /// - `[0x02] u16` — LV frame height (pixels)
  /// - `[0x08] u16` — LV crop width (unused here)
  /// - `[0x0A] u16` — LV crop height (unused here)
  /// - `[0x10] u16` — AF box x (image-relative, in LV pixels)
  /// - `[0x12] u16` — AF box y
  /// - `[0x14] u16` — AF box width
  /// - `[0x16] u16` — AF box height
  /// - `[0x18] u16` — Focus area x (frame-relative)
  /// - `[0x1A] u16` — Focus area y
  /// - `[0x1C] u16` — Focus area width
  /// - `[0x1E] u16` — Focus area height
  ///
  /// Older / non-Z bodies use a different layout; when we can't confidently
  /// map a field we leave it null rather than emit a bogus value.
  static LvHeader _parseHeader(Uint8List bytes) {
    if (bytes.length < 4) return const LvHeader();
    final view = ByteData.sublistView(bytes);

    int? _u16(int off) {
      if (off + 2 > bytes.length) return null;
      final v = view.getUint16(off, Endian.little);
      return v == 0 ? null : v;
    }

    final imgW = _u16(0x00);
    final imgH = _u16(0x02);

    LvRect? _rect(int off) {
      if (off + 8 > bytes.length) return null;
      final x = view.getUint16(off, Endian.little);
      final y = view.getUint16(off + 2, Endian.little);
      final w = view.getUint16(off + 4, Endian.little);
      final h = view.getUint16(off + 6, Endian.little);
      if (w == 0 || h == 0) return null;
      return LvRect(x: x, y: y, width: w, height: h);
    }

    return LvHeader(
      imageWidth: imgW,
      imageHeight: imgH,
      afRect: _rect(0x10),
      focusArea: _rect(0x18),
    );
  }
}
