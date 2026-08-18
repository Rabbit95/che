import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../../shared/providers/live_view_provider.dart';

/// The Live View canvas. When a real frame is available it decodes and
/// renders the JPEG; otherwise it falls back to the painted warm-scene
/// stand-in so the surface never looks broken during warmup.
class LvScene extends ConsumerWidget {
  const LvScene({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(liveViewProvider);
    final state = asyncState.value ?? LiveViewState.idle;
    final frame = state.frame;

    if (frame != null && frame.jpeg.isNotEmpty) {
      return _JpegFrame(jpeg: frame.jpeg);
    }

    return _WarmingScene(status: state.status, error: state.error);
  }
}

/// Decoded JPEG panel. Uses [Image.memory] with `gaplessPlayback` so the
/// previous frame stays on-screen while the next one paints — otherwise
/// the widget flashes to blank between frames.
class _JpegFrame extends StatelessWidget {
  const _JpegFrame({required this.jpeg});
  final Uint8List jpeg;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.center,
        child: Image.memory(
          jpeg,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }
}

/// Fallback for the pre-first-frame window (starting) and the "connected
/// but LV never came up" case. Painted stand-in mirrors the mockup so the
/// surface has something warm to look at while the camera is warming.
class _WarmingScene extends StatelessWidget {
  const _WarmingScene({required this.status, required this.error});
  final LiveViewStatus status;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1210), Color(0xFF0A0808)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: CustomPaint(painter: _WarmScenePainter())),
          if (status == LiveViewStatus.starting)
            const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (status == LiveViewStatus.error)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '实时取景启动失败\n${_shortError(error)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _shortError(Object? e) {
    if (e == null) return '未连接相机';
    if (e is PtpResponseException) {
      return '${e.codeLabel} · ${_hint(e.code)}';
    }
    return e.toString();
  }

  static String _hint(int code) => switch (code) {
        PtpResponseCode.deviceBusy => '相机忙，稍后重试',
        PtpResponseCode.operationNotSupported => '当前模式不支持 LV',
        PtpResponseCode.accessDenied => '相机未处于控制模式',
        _ => '请检查相机菜单',
      };
}

class _WarmScenePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final warm = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF4A3020).withOpacity(0.9),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * 0.3, size.height * 0.4),
        radius: size.width * 0.5,
      ));
    canvas.drawRect(Offset.zero & size, warm);

    final cool = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF22181E).withOpacity(0.8),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * 0.7, size.height * 0.6),
        radius: size.width * 0.5,
      ));
    canvas.drawRect(Offset.zero & size, cool);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
