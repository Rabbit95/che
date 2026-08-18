import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One Live-View frame decoded from `GetLiveViewImageEx` (0x9428).
///
/// The Nikon blob is 384 bytes of header + a JPEG. [header] carries the
/// structured overlay metadata (AF box, focus area, exposure); [jpeg] is
/// the raw JPEG bytes ready to hand to any image decoder.
@immutable
final class LiveViewFrame {
  const LiveViewFrame({
    required this.jpeg,
    required this.header,
    required this.timestamp,
  });

  final Uint8List jpeg;
  final LvHeader header;
  final DateTime timestamp;
}

/// Overlay/metadata fields decoded from a Live View frame header.
///
/// Field layout varies across models; presence of most fields is optional
/// so consumers can render whatever the current camera actually provides.
@immutable
final class LvHeader {
  const LvHeader({
    this.imageWidth,
    this.imageHeight,
    this.afRect,
    this.focusArea,
    this.histogram,
    this.exposure,
  });

  final int? imageWidth;
  final int? imageHeight;
  final LvRect? afRect;
  final LvRect? focusArea;
  final List<int>? histogram; // 4 x 256 typically (RGB + L)
  final LvExposure? exposure;
}

@immutable
final class LvRect {
  const LvRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

@immutable
final class LvExposure {
  const LvExposure({
    this.iso,
    this.shutterNumerator,
    this.shutterDenominator,
    this.fNumberHundredths,
    this.exposureBiasThirds,
  });

  final int? iso;
  final int? shutterNumerator;
  final int? shutterDenominator;
  final int? fNumberHundredths;
  final int? exposureBiasThirds;
}
