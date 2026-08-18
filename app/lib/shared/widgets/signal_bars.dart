import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 4-bar signal strength indicator. [bars] is 0..4.
class SignalBars extends StatelessWidget {
  const SignalBars({required this.bars, this.color, this.size = 12, super.key});

  final int bars;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.info;
    return SizedBox(
      height: size,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          final active = i < bars;
          final h = (i + 1) * (size / 4);
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
            child: Container(
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: active ? c : c.withOpacity(0.25),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}
