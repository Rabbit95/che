import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../router.dart';
import '../../shared/providers/connection_providers.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/pill_button.dart';
import 'connection_controller.dart';

/// Screen 3 — Connecting. Runs the PTP handshake (Wi-Fi or USB) via
/// [ConnectionController] and streams progress into the on-screen log.
class ConnectingScreen extends ConsumerStatefulWidget {
  const ConnectingScreen({
    required this.host,
    required this.cameraName,
    required this.ssid,
    this.channel = TransportChannel.wifi,
    this.usbSerial,
    this.iccDeviceId,
    super.key,
  });

  final String host;
  final String cameraName;
  final String ssid;
  final TransportChannel channel;

  /// USB serial for scoping when multiple cameras are plugged in.
  final String? usbSerial;

  /// iOS ICA persistent device id — required when [channel] is
  /// [TransportChannel.icc].
  final String? iccDeviceId;

  @override
  ConsumerState<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends ConsumerState<ConnectingScreen> {
  final List<ConnectionLog> _log = [];
  ConnectionController? _controller;
  StreamSubscription<ConnectionEvent>? _sub;
  ConnectionFailed? _failure;
  bool _succeeded = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    // If we handed the session off to the app, don't tear it down.
    if (!_succeeded) {
      unawaited(_controller?.cancel());
    }
    super.dispose();
  }

  void _start() {
    setState(() {
      _log.clear();
      _failure = null;
      _succeeded = false;
    });
    final controller = ConnectionController();
    _controller = controller;
    final stream = switch (widget.channel) {
      TransportChannel.wifi => controller.connectWifi(
          host: widget.host,
          friendlyName: 'Nikon Z Control · ${widget.host}',
        ),
      TransportChannel.usb => controller.connectUsb(
          usbSerial: widget.usbSerial,
          friendlyName: 'Nikon Z Control · USB',
        ),
      TransportChannel.icc => controller.connectIcc(
          iccDeviceId: widget.iccDeviceId ?? '',
          friendlyName: 'Nikon Z Control · USB-C',
        ),
    };
    _sub = stream.listen(_onEvent);
  }

  void _onEvent(ConnectionEvent event) {
    if (!mounted) return;
    switch (event) {
      case ConnectionLog():
        setState(() => _log.add(event));
      case ConnectionReady():
        setState(() => _succeeded = true);
        _handleReady(event);
      case ConnectionFailed():
        setState(() => _failure = event);
    }
  }

  void _handleReady(ConnectionReady ready) {
    final channelPrefix = switch (widget.channel) {
      TransportChannel.wifi => 'wifi',
      TransportChannel.usb => 'usb',
      TransportChannel.icc => 'icc',
    };
    ref.read(activeConnectionProvider.notifier).state = ActiveConnection(
      camera: DiscoveredCamera(
        id: '$channelPrefix-${ready.deviceInfo.serialNumber}',
        name: ready.deviceInfo.model,
        channel: widget.channel,
        host: widget.channel == TransportChannel.wifi ? widget.host : null,
        serialNumber: ready.deviceInfo.serialNumber,
        firmware: ready.deviceInfo.deviceVersion,
      ),
      deviceInfo: ready.deviceInfo,
      client: ready.client,
    );
    // Small delay so the READY log line has a chance to render before the
    // route transition; feels less abrupt than an immediate hop.
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      context.go(AppRoute.liveView);
    });
  }

  void _retry() {
    unawaited(_sub?.cancel());
    unawaited(_controller?.cancel());
    _start();
  }

  void _abortAndPop() {
    unawaited(_sub?.cancel());
    unawaited(_controller?.cancel());
    context.go(AppRoute.discovery);
  }

  @override
  Widget build(BuildContext context) {
    final failed = _failure;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _abortAndPop,
        ),
        title: Text(
          failed == null
              ? '正在连接 ${widget.cameraName}'
              : '连接失败 · ${widget.cameraName}',
          style: const TextStyle(fontSize: 15),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            _ConnVisual(failed: failed != null, succeeded: _succeeded),
            const SizedBox(height: 28),
            _ChannelSummary(
              channel: widget.channel,
              host: widget.host,
              ssid: widget.ssid,
            ),
            const SizedBox(height: 28),
            _ConnLog(lines: _log),
            const SizedBox(height: 20),
            _ActionButtons(
              failed: failed != null,
              onCancel: _abortAndPop,
              onRetry: _retry,
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.failed,
    required this.onCancel,
    required this.onRetry,
  });

  final bool failed;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!failed) {
      return PillButton(
        label: '取消',
        variant: PillButtonVariant.ghost,
        expand: true,
        onPressed: onCancel,
      );
    }
    return Row(
      children: [
        Expanded(
          child: PillButton(
            label: '返回',
            variant: PillButtonVariant.ghost,
            expand: true,
            onPressed: onCancel,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: PillButton(
            label: '重试',
            expand: true,
            onPressed: onRetry,
          ),
        ),
      ],
    );
  }
}

class _ConnVisual extends StatelessWidget {
  const _ConnVisual({required this.failed, required this.succeeded});

  final bool failed;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _ConnNode(icon: Icons.phone_iphone_rounded),
        const SizedBox(width: 24),
        _LinkFlow(failed: failed, succeeded: succeeded),
        const SizedBox(width: 24),
        _ConnNode(
          icon: Icons.camera_alt_outlined,
          accent: !failed,
          error: failed,
        ),
      ],
    );
  }
}

class _ConnNode extends StatelessWidget {
  const _ConnNode({
    required this.icon,
    this.accent = false,
    this.error = false,
  });

  final IconData icon;
  final bool accent;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? AppColors.danger
        : accent
            ? AppColors.accent
            : AppColors.text2;
    final borderColor = error
        ? AppColors.danger.withOpacity(0.25)
        : accent
            ? AppColors.accentSubtle
            : AppColors.border;
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
      ),
      child: Icon(icon, size: 34, color: color),
    );
  }
}

class _LinkFlow extends StatefulWidget {
  const _LinkFlow({required this.failed, required this.succeeded});

  final bool failed;
  final bool succeeded;

  @override
  State<_LinkFlow> createState() => _LinkFlowState();
}

class _LinkFlowState extends State<_LinkFlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.failed) {
      return const Icon(Icons.link_off_rounded,
          color: AppColors.danger, size: 22);
    }
    if (widget.succeeded) {
      return const Icon(Icons.link_rounded,
          color: AppColors.success, size: 22);
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            final delay = i * 0.2;
            final t = ((_c.value - delay) % 1.0).clamp(0.0, 1.0);
            final opacity =
                t < 0.5 ? 0.2 + t * 1.6 : 1.0 - (t - 0.5) * 1.6;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Opacity(
                opacity: opacity.clamp(0.2, 1.0),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ChannelSummary extends StatelessWidget {
  const _ChannelSummary({
    required this.channel,
    required this.host,
    required this.ssid,
  });

  final TransportChannel channel;
  final String host;
  final String ssid;

  @override
  Widget build(BuildContext context) {
    final isUsb =
        channel == TransportChannel.usb || channel == TransportChannel.icc;
    final primary = isUsb
        ? 'USB · PTP-USB bulk'
        : 'Wi-Fi · $host:15740';
    final primaryColor = isUsb ? AppColors.success : AppColors.info;
    final secondary =
        isUsb ? 'MTP/PTP 模式 · claim USB interface' : 'SSID: $ssid';
    return Column(
      children: [
        RichText(
          text: TextSpan(
            style: const TextStyle(color: AppColors.text2, fontSize: 15),
            children: [
              const TextSpan(text: '通道: '),
              TextSpan(
                text: primary,
                style: AppTypography.mono.copyWith(
                  color: primaryColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          secondary,
          style: AppTypography.mono.copyWith(
            color: AppColors.text4,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _ConnLog extends StatelessWidget {
  const _ConnLog({required this.lines});
  final List<ConnectionLog> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tile,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines) _row(l),
        ],
      ),
    );
  }

  Widget _row(ConnectionLog l) {
    final color = switch (l.level) {
      ConnectionLogLevel.error => AppColors.danger,
      ConnectionLogLevel.active => AppColors.accent,
      ConnectionLogLevel.ok => AppColors.success,
      ConnectionLogLevel.info => AppColors.text2,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              l.tag,
              style: AppTypography.mono.copyWith(
                fontSize: 11,
                color: AppColors.text4,
              ),
            ),
          ),
          Expanded(
            child: Text(
              l.text,
              style: AppTypography.mono.copyWith(fontSize: 11, color: color),
            ),
          ),
          const SizedBox(width: 8),
          _trailing(l),
        ],
      ),
    );
  }

  Widget _trailing(ConnectionLog l) {
    if (l.level == ConnectionLogLevel.active) {
      return const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1,
          color: AppColors.accent,
        ),
      );
    }
    final ms = l.elapsedMs;
    if (ms == null) return const SizedBox.shrink();
    return Text(
      '${ms}ms',
      style: AppTypography.mono.copyWith(
        fontSize: 11,
        color: AppColors.text4,
      ),
    );
  }
}
