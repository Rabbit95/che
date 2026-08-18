import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Floating monospace chip used across the Live View HUD.
///
/// Rendered on top of the LV frame, so it needs an opaque blurred
/// background to stay legible over arbitrary scene content.
class HudChip extends StatelessWidget {
  const HudChip({
    required this.child,
    this.color,
    this.strong = false,
    super.key,
  });

  final Widget child;
  final Color? color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final content = DefaultTextStyle(
      style: AppTypography.mono.copyWith(
        fontSize: 11,
        color: color ?? AppColors.text,
      ),
      child: IconTheme(
        data: IconThemeData(size: 12, color: color ?? AppColors.text),
        child: child,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(strong ? 0.75 : 0.55),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: content,
        ),
      ),
    );
  }
}
