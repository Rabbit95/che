import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../router.dart';
import '../../shared/providers/connection_providers.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/channel_badge.dart';
import '../../shared/widgets/section_label.dart';
import '../../shared/widgets/signal_bars.dart';

/// Screen 1 — Discovery. Lists cameras from mDNS + USB hotplug + history.
class DiscoveryScreen extends ConsumerWidget {
  const DiscoveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovery = ref.watch(discoveryProvider);
    final recent = ref.watch(recentCamerasProvider);
    final active = ref.watch(activeConnectionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('相机'),
        actions: [
          IconButton(
            tooltip: '手动添加',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => context.push(AppRoute.onboarding),
          ),
          IconButton(
            tooltip: '扫描',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => ref.invalidate(discoveryProvider),
          ),
        ],
      ),
      body: discovery.when(
        data: (cams) => _CameraList(
          cameras: cams,
          activeCameraId: active?.camera.id,
          recent: recent,
        ),
        error: (e, _) => Center(
          child: Text('$e', style: AppTypography.bodySecondary),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _CameraList extends StatelessWidget {
  const _CameraList({
    required this.cameras,
    required this.activeCameraId,
    required this.recent,
  });

  final List<DiscoveredCamera> cameras;
  final String? activeCameraId;
  final List<DiscoveredCamera> recent;

  @override
  Widget build(BuildContext context) {
    final connected = cameras.where((c) => c.id == activeCameraId).toList();
    final nearby = cameras.where((c) => c.id != activeCameraId).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (connected.isNotEmpty) ...[
          const SectionLabel('已连接'),
          for (final c in connected)
            _CameraCard(camera: c, selected: true),
        ],
        if (nearby.isNotEmpty) ...[
          const SectionLabel('附近'),
          for (final c in nearby)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _CameraCard(camera: c),
            ),
        ],
        if (recent.isNotEmpty) ...[
          const SectionLabel('最近'),
          for (final c in recent)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Opacity(
                opacity: 0.55,
                child: _CameraCard(camera: c, offline: true),
              ),
            ),
        ],
      ],
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({
    required this.camera,
    this.selected = false,
    this.offline = false,
  });

  final DiscoveredCamera camera;
  final bool selected;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final gradient = selected
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x0FE8B455), AppColors.surface],
          )
        : null;

    return InkWell(
      borderRadius: AppRadius.card,
      onTap: offline
          ? null
          : () => context.pushNamed(
                'connecting',
                queryParameters: {
                  'name': camera.name,
                  'channel': switch (camera.channel) {
                    TransportChannel.usb => 'usb',
                    TransportChannel.icc => 'icc',
                    TransportChannel.wifi => 'wifi',
                  },
                  if (camera.host != null) 'host': camera.host!,
                  if (camera.host != null) 'ssid': camera.host!,
                  if (camera.usbSerial != null) 'usbSerial': camera.usbSerial!,
                },
              ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: gradient,
          color: gradient == null ? AppColors.surface : null,
          borderRadius: AppRadius.card,
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            _CameraThumb(highlighted: selected),
            const SizedBox(width: 14),
            Expanded(child: _CameraInfo(camera: camera, offline: offline)),
            if (!offline) ChannelBadge(channel: camera.channel),
          ],
        ),
      ),
    );
  }
}

class _CameraThumb extends StatelessWidget {
  const _CameraThumb({required this.highlighted});
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2A34), Color(0xFF17171D)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Icon(
        Icons.camera_alt_outlined,
        color: highlighted ? AppColors.accent : AppColors.text2,
        size: 28,
      ),
    );
  }
}

class _CameraInfo extends StatelessWidget {
  const _CameraInfo({required this.camera, required this.offline});

  final DiscoveredCamera camera;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          camera.name,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.15,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 3),
        DefaultTextStyle(
          style: AppTypography.mono.copyWith(color: AppColors.text3),
          child: Row(
            children: [
              Flexible(child: _sub(camera, offline)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sub(DiscoveredCamera c, bool offline) {
    if (offline) return const Text('3 天前 · 离线');
    final parts = <Widget>[];
    if (c.serialNumber != null) parts.add(Text('SN: ${c.serialNumber}'));
    if (c.host != null) parts.add(Text(c.host!));
    if (c.firmware != null) parts.add(Text('固件 ${c.firmware}'));
    if (c.signalBars != null) parts.add(SignalBars(bars: c.signalBars!));

    final joined = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) joined.add(const _Dot());
      joined.add(parts[i]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: joined);
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.text3.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
