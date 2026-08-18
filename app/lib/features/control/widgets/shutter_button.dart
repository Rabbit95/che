import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import 'live_view_hud.dart';

/// Large shutter button. Photo = white disc with inner ring; Video =
/// red disc that morphs to a rounded-rect stop icon when [recording].
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    required this.mode,
    required this.recording,
    required this.onTap,
    super.key,
  });

  final CaptureMode mode;
  final bool recording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isVideo = mode == CaptureMode.video;
    final ringColor = (isVideo ? AppColors.record : Colors.white).withOpacity(0.3);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 4),
          color: isVideo ? AppColors.record : Colors.white,
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: isVideo ? (recording ? 22 : 24) : 52,
            height: isVideo ? (recording ? 22 : 24) : 52,
            decoration: BoxDecoration(
              color: isVideo ? Colors.white : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(isVideo ? (recording ? 2 : 4) : 26),
              border: isVideo
                  ? null
                  : Border.all(color: Colors.black.withOpacity(0.15), width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}
