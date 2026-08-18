import 'package:flutter/material.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/hud_chip.dart';

enum CaptureMode { photo, video }

enum DriveMode { single, burst }

/// Floating HUD overlaid on the Live View frame.
///
/// Layout follows the mockup: channel + fps top-left, battery + storage
/// top-right, histogram (photo) or waveform (video) below, AF box in the
/// middle, mode chips bottom center.
class LiveViewHud extends StatelessWidget {
  const LiveViewHud({
    required this.mode,
    required this.recording,
    required this.channel,
    required this.fps,
    required this.cameraName,
    required this.recElapsed,
    required this.onTapFocus,
    super.key,
  });

  final CaptureMode mode;
  final bool recording;
  final TransportChannel channel;
  final double fps;
  final String cameraName;
  final Duration recElapsed;

  /// Called with the tap position AND the current widget size — the
  /// state layer needs both to map screen coordinates to LV pixels
  /// before firing ChangeAfArea.
  final void Function(Offset position, Size widgetSize) onTapFocus;

  @override
  Widget build(BuildContext context) {
    final isVideo = mode == CaptureMode.video;
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        fit: StackFit.expand,
        children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) => onTapFocus(d.localPosition, size),
        ),
        // Top-left cluster
        Positioned(
          top: 12,
          left: 12,
          child: recording
              ? _RecTimer(elapsed: recElapsed)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HudChip(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_channelIcon(channel), size: 10),
                          const SizedBox(width: 6),
                          Text.rich(
                            TextSpan(
                              text: '${_channelLabel(channel)} · ',
                              children: [
                                TextSpan(
                                  text: cameraName,
                                  style: const TextStyle(
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    HudChip(
                      color: AppColors.success,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: AppColors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text('${fps.toStringAsFixed(1)} fps'),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        // Top-right cluster
        Positioned(
          top: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (isVideo)
                const HudChip(child: Text('4K 60p · N-Log'))
              else
                const HudChip(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.battery_5_bar_rounded, size: 10),
                      SizedBox(width: 4),
                      Text('82%'),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              const HudChip(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sd_card_outlined, size: 10),
                    SizedBox(width: 4),
                    Text('CFe · 128 GB'),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Right side: histogram (photo) or waveform (video)
        Positioned(
          top: 100,
          right: 12,
          child: SizedBox(
            width: 96,
            height: isVideo ? 60 : 48,
            child: isVideo ? const _Waveform() : const _Histogram(),
          ),
        ),
        // AF box (approximate center)
        Positioned.fill(child: _AfBox(recording: recording)),
        // Bottom chips
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: isVideo
                ? const [
                    HudChip(
                      color: AppColors.warn,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 10),
                          SizedBox(width: 4),
                          Text('Zebra 90%'),
                        ],
                      ),
                    ),
                    SizedBox(width: 8),
                    HudChip(child: Text('Peaking · 高')),
                    SizedBox(width: 8),
                    HudChip(child: Text('LUT · Rec709')),
                  ]
                : const [
                    HudChip(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.center_focus_strong_outlined, size: 10),
                          SizedBox(width: 4),
                          Text('AF-C · 单点'),
                        ],
                      ),
                    ),
                    SizedBox(width: 8),
                    HudChip(child: Text('3:2 · L')),
                    SizedBox(width: 8),
                    HudChip(child: Text('M 档')),
                  ],
          ),
        ),
      ],
    );
    });
  }

  IconData _channelIcon(TransportChannel c) => switch (c) {
        TransportChannel.usb => Icons.usb_rounded,
        TransportChannel.wifi => Icons.wifi_rounded,
        TransportChannel.icc => Icons.usb_rounded,
      };

  String _channelLabel(TransportChannel c) => switch (c) {
        TransportChannel.usb || TransportChannel.icc => 'USB',
        TransportChannel.wifi => 'Wi-Fi',
      };
}

class _RecTimer extends StatelessWidget {
  const _RecTimer({required this.elapsed});
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final s = elapsed.inSeconds;
    final label = 'REC · '
        '${(s ~/ 3600).toString().padLeft(2, '0')}:'
        '${((s ~/ 60) % 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.record.withOpacity(0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              fontFamilyFallback: AppTypography.monoFontFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _Histogram extends StatelessWidget {
  const _Histogram();

  @override
  Widget build(BuildContext context) {
    const bins = [20, 35, 50, 65, 78, 88, 92, 85, 70, 55, 42, 30, 22, 15, 10, 8, 5, 3];
    return HudChip(
      strong: true,
      child: SizedBox(
        width: 88,
        height: 40,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final b in bins)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  height: b / 100 * 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.accent,
                        AppColors.accent.withOpacity(0.4),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform();

  @override
  Widget build(BuildContext context) {
    return HudChip(
      strong: true,
      child: SizedBox(
        width: 88,
        height: 52,
        child: CustomPaint(painter: _WaveformPainter()),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, size.height * 0.83);
    final pts = <Offset>[
      Offset(size.width * 0.10, size.height * 0.75),
      Offset(size.width * 0.25, size.height * 0.63),
      Offset(size.width * 0.35, size.height * 0.33),
      Offset(size.width * 0.45, size.height * 0.25),
      Offset(size.width * 0.55, size.height * 0.42),
      Offset(size.width * 0.65, size.height * 0.67),
      Offset(size.width * 0.75, size.height * 0.75),
      Offset(size.width * 0.85, size.height * 0.80),
      Offset(size.width, size.height * 0.83),
    ];
    for (final p in pts) {
      path.lineTo(p.dx, p.dy);
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.accent.withOpacity(0.9),
            AppColors.accent.withOpacity(0.2),
          ],
        ).createShader(Offset.zero & size),
    );

    // Reference line at 90 %
    final ref = Paint()
      ..color = AppColors.record.withOpacity(0.6)
      ..strokeWidth = 0.6;
    canvas.drawLine(
      Offset(0, size.height * 0.14),
      Offset(size.width, size.height * 0.14),
      ref,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AfBox extends StatelessWidget {
  const _AfBox({required this.recording});
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: const Alignment(0.05, 0.02),
      child: IgnorePointer(
        child: CustomPaint(
          size: const Size(84, 84),
          painter: _AfPainter(
            color: recording ? AppColors.record : AppColors.success,
          ),
        ),
      ),
    );
  }
}

class _AfPainter extends CustomPainter {
  _AfPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final border = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      border,
    );

    // Four L-shaped corner markers
    final marker = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const arm = 14.0;
    // TL
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(arm, 0), marker);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, arm), marker);
    // TR
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(arm, 0), marker);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, arm), marker);
    // BL
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(arm, 0), marker);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft - const Offset(0, arm), marker);
    // BR
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(arm, 0), marker);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(0, arm), marker);
  }

  @override
  bool shouldRepaint(covariant _AfPainter old) => old.color != color;
}
