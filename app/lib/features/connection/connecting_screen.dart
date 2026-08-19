import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Multi-line preamble prepended to the clipboard-copied log so users
  /// can send us a self-contained diagnostic dump without having to
  /// re-type the device / channel / platform context.
  String _logHeader() {
    final channel = switch (widget.channel) {
      TransportChannel.wifi => 'wifi',
      TransportChannel.usb => 'usb',
      TransportChannel.icc => 'icc',
    };
    return 'Nikon Z Control · 连接日志\n'
        'camera: ${widget.cameraName}\n'
        'channel: $channel\n'
        'host: ${widget.host}\n'
        'ssid: ${widget.ssid}\n'
        'iccDeviceId: ${widget.iccDeviceId ?? "-"}\n'
        'platform: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}';
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
    // NOTE: intentionally NO auto-navigation to Live View — Phase A wants
    // the user to be able to copy the connect log after a slow success,
    // which is impossible if the screen bounces to LV automatically.
    // The "进入实时取景" primary button in `_ActionButtons` drives the
    // navigation when the user is done inspecting the log.
  }

  void _enterLiveView() {
    context.go(AppRoute.liveView);
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
          failed != null
              ? '连接失败 · ${widget.cameraName}'
              : _succeeded
                  ? '已连接 · ${widget.cameraName}'
                  : '正在连接 ${widget.cameraName}',
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
            _ConnLog(
              lines: _log,
              header: _logHeader(),
            ),
            const SizedBox(height: 20),
            _ActionButtons(
              failed: failed != null,
              succeeded: _succeeded,
              onCancel: _abortAndPop,
              onRetry: _retry,
              onEnterLiveView: _enterLiveView,
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
    required this.succeeded,
    required this.onCancel,
    required this.onRetry,
    required this.onEnterLiveView,
  });

  final bool failed;
  final bool succeeded;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onEnterLiveView;

  @override
  Widget build(BuildContext context) {
    if (succeeded) {
      // Do NOT auto-navigate: users need to be able to copy the connect
      // log after a slow success too. Ghost "返回" preserves the escape
      // hatch; primary "进入实时取景" is the happy path.
      return Row(
        children: [
          Expanded(
            child: PillButton(
              label: '返回列表',
              variant: PillButtonVariant.ghost,
              expand: true,
              onPressed: onCancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PillButton(
              label: '进入实时取景',
              expand: true,
              onPressed: onEnterLiveView,
            ),
          ),
        ],
      );
    }
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

class _ConnLog extends StatefulWidget {
  const _ConnLog({required this.lines, required this.header});
  final List<ConnectionLog> lines;

  /// Extra context prepended when the user taps "复制日志" — device name,
  /// channel, platform. Not rendered inside the panel; only in clipboard.
  final String header;

  @override
  State<_ConnLog> createState() => _ConnLogState();
}

class _ConnLogState extends State<_ConnLog> {
  Timer? _ticker;
  Stopwatch? _activeSw;
  int _activeIndex = -1;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _syncActive();
  }

  @override
  void didUpdateWidget(covariant _ConnLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncActive();
    // New line arrived — pin scroll to the tail so the user always sees
    // the freshest log entry without having to scroll manually.
    if (widget.lines.length != oldWidget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Detect whether the tail of the log is an active step and start / stop
  /// the ticker accordingly. The ticker only runs while an active row exists,
  /// so idle screens don't rebuild once a second forever.
  void _syncActive() {
    final lines = widget.lines;
    final lastIdx = lines.length - 1;
    final tail = lastIdx >= 0 ? lines[lastIdx] : null;
    final isActive =
        tail != null && tail.level == ConnectionLogLevel.active;

    if (!isActive) {
      _ticker?.cancel();
      _ticker = null;
      _activeSw = null;
      _activeIndex = -1;
      return;
    }
    if (lastIdx != _activeIndex) {
      _activeIndex = lastIdx;
      _activeSw = Stopwatch()..start();
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    final lastIdx = lines.length - 1;
    return Container(
      constraints: const BoxConstraints(minHeight: 40, maxHeight: 260),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tile,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < lines.length; i++)
                    _row(lines[i], i == lastIdx),
                  _stallHint(lastIdx >= 0 ? lines[lastIdx] : null),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Top-right "📋 复制日志" affordance. Always visible so a user who's
  /// been staring at a spinner for two minutes can send us the trace
  /// without waiting for the connect to fail (or succeed).
  Widget _header() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          '连接日志',
          style: AppTypography.mono.copyWith(
            fontSize: 10,
            color: AppColors.text4,
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _copyToClipboard(context),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.copy_rounded,
                  size: 12,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 4),
                Text(
                  '复制日志',
                  style: AppTypography.mono.copyWith(
                    fontSize: 11,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    final buf = StringBuffer()
      ..writeln(widget.header)
      ..writeln('=' * 40);
    for (final l in widget.lines) {
      final elapsed =
          l.elapsedMs == null ? '        ' : '${l.elapsedMs}ms'.padLeft(8);
      buf.writeln('[$elapsed] [${l.tag.padRight(6)}] '
          '${_levelSlug(l.level)} ${l.text}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('日志已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  static String _levelSlug(ConnectionLogLevel level) => switch (level) {
        ConnectionLogLevel.active => 'ACTIVE',
        ConnectionLogLevel.ok => 'OK    ',
        ConnectionLogLevel.info => 'INFO  ',
        ConnectionLogLevel.error => 'ERROR ',
      };

  Widget _row(ConnectionLog l, bool isLast) {
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
          _trailing(l, isLast),
        ],
      ),
    );
  }

  Widget _trailing(ConnectionLog l, bool isLast) {
    if (l.level == ConnectionLogLevel.active) {
      final elapsedText = isLast && _activeSw != null
          ? '${_activeSw!.elapsed.inSeconds}s'
          : null;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (elapsedText != null) ...[
            Text(
              elapsedText,
              style: AppTypography.mono.copyWith(
                fontSize: 11,
                color: AppColors.text4,
              ),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1,
              color: AppColors.accent,
            ),
          ),
        ],
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

  /// Extra italic hint below the active step once we've been stalled for
  /// more than 10 s with no further log lines. The exact copy is chosen by
  /// the tag of the active row so we can nudge users at the right layer
  /// (ICC = check iOS trust dialog; TCP = check camera Wi-Fi; etc.).
  Widget _stallHint(ConnectionLog? tail) {
    if (tail == null || tail.level != ConnectionLogLevel.active) {
      return const SizedBox.shrink();
    }
    final elapsedSec = _activeSw?.elapsed.inSeconds ?? 0;
    if (elapsedSec < 10) return const SizedBox.shrink();
    final hint = _hintForActive(tail.tag);
    if (hint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 60),
      child: Text(
        hint,
        style: AppTypography.mono.copyWith(
          fontSize: 10,
          color: AppColors.text4,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  static String? _hintForActive(String tag) => switch (tag) {
        'ICC' =>
          '提示：iOS 每次连接都可能等待系统权限或相机内部准备。'
              '请留意手机屏幕是否有「允许有线配件」对话框；'
              '若确认已授权，可尝试拔插一次 USB-C 线。',
        'TCP' => '提示：请确认手机已加入相机 Wi-Fi 且 IP 可达。',
        'USB' => '提示：请检查数据线以及相机的 USB 模式（应为 MTP/PTP）。',
        _ => null,
      };
}
