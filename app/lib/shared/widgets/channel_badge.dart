import 'package:flutter/material.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../theme/app_theme.dart';

/// Small pill showing which physical channel a connection is using.
///
/// Green = USB, blue = Wi-Fi, purple = BLE. Follows the color contract
/// from the mockup so the same signal is legible across every screen.
class ChannelBadge extends StatelessWidget {
  const ChannelBadge({required this.channel, this.compact = false, super.key});

  final TransportChannel channel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label, icon) = switch (channel) {
      TransportChannel.usb => (
          const Color(0x2422C55E),
          const Color(0xFF6CE09D),
          'USB',
          Icons.usb_rounded,
        ),
      TransportChannel.wifi => (
          const Color(0x243B82F6),
          const Color(0xFF7EA9F3),
          'Wi-Fi',
          Icons.wifi_rounded,
        ),
      TransportChannel.icc => (
          const Color(0x2422C55E),
          const Color(0xFF6CE09D),
          'USB',
          Icons.usb_rounded,
        ),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: 2,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadius.chip),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: fg),
          if (!compact) ...[
            const SizedBox(width: 4),
            Text(label, style: AppTypography.badge.copyWith(color: fg)),
          ],
        ],
      ),
    );
  }
}
