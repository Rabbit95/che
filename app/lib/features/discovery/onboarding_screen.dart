import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_ptp_flutter/nikon_ptp_flutter.dart';

import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/pill_button.dart';

/// Screen 2 — Onboarding wizard shown when Discovery returns empty.
///
/// 4 steps (choose method / turn on Wi-Fi on camera / join AP / return to app)
/// plus a live-scan indicator and fallback pills for manual IP / USB.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('连接向导', style: TextStyle(fontSize: 15)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _WizardHero(),
          const _StepsList(),
          const _ScanIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: PillButton(
                    label: '手动输入 IP',
                    variant: PillButtonVariant.ghost,
                    expand: true,
                    onPressed: () {},
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PillButton(
                    label: 'USB 有线',
                    variant: PillButtonVariant.ghost,
                    expand: true,
                    onPressed: () => _launchUsbConnect(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _launchUsbConnect(BuildContext context) async {
    // Route to platform-specific discovery. iOS uses ImageCaptureCore
    // (ICCameraDevice) which is a completely different stack from the
    // quick_usb-based path used on Android/desktop.
    if (!kIsWeb && Platform.isIOS) {
      await _launchIccConnect(context);
      return;
    }
    // One-shot scan to prefill the ConnectingScreen with a specific device
    // serial when possible — otherwise ConnectingScreen picks the first
    // Nikon it sees.
    List<UsbCameraDescriptor> cams;
    try {
      cams = await UsbCameraDiscovery().scanOnce();
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('USB 不可用: $e'),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    if (cams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '未检测到 USB 相机。请确认已用数据线连接，'
            '并把相机 USB 模式设为 MTP/PTP。',
          ),
        ),
      );
      return;
    }
    final target = cams.first;
    context.pushNamed(
      'connecting',
      queryParameters: {
        'name': target.modelName,
        'channel': 'usb',
        'usbSerial': target.identifier,
      },
    );
  }

  Future<void> _launchIccConnect(BuildContext context) async {
    List<IccCameraDescriptor> cams;
    try {
      cams = await IccCameraDiscovery().scanOnce();
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('USB 不可用: $e')),
      );
      return;
    }
    if (!context.mounted) return;
    if (cams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '未检测到 USB 相机。请用 USB-C 数据线连接，'
            '相机开机后把 USB 模式设为 PTP，'
            '首次连接需在系统弹窗里允许"有线配件"权限。',
          ),
        ),
      );
      return;
    }
    final target = cams.first;
    context.pushNamed(
      'connecting',
      queryParameters: {
        'name': target.modelName,
        'channel': 'icc',
        'iccDeviceId': target.deviceId,
      },
    );
  }
}

class _WizardHero extends StatelessWidget {
  const _WizardHero();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
      child: Column(
        children: [
          const _WizardArt(),
          const SizedBox(height: 20),
          const Text(
            '让相机准备好',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.44,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 8),
          const SizedBox(
            width: 300,
            child: Text(
              '没检测到附近的尼康 Z 相机。按下面步骤操作，App 会自动发现。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.text2, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardArt extends StatelessWidget {
  const _WizardArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: AppColors.accent.withOpacity(0.3),
                width: 1,
                style: BorderStyle.solid,
              ),
            ),
          ),
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.surface3, AppColors.surface],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: const Icon(
              Icons.camera_alt_outlined,
              size: 42,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepsList extends StatelessWidget {
  const _StepsList();

  @override
  Widget build(BuildContext context) {
    const steps = <_StepData>[
      _StepData(
        state: _StepState.done,
        title: '选择连接方式',
        detail: 'Wi-Fi（无线）',
      ),
      _StepData(
        state: _StepState.active,
        index: 2,
        title: '在相机上开启 Wi-Fi',
        detail: '进入相机菜单：',
        path: '网络 → 连接到智能设备 → 开始',
      ),
      _StepData(
        state: _StepState.pending,
        index: 3,
        title: '用手机连相机的 Wi-Fi',
        detail: 'SSID 类似 NIKON-Zx-xxxx',
      ),
      _StepData(
        state: _StepState.pending,
        index: 4,
        title: '返回本 App',
        detail: '会自动扫描并连接',
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          for (final s in steps) ...[
            _StepTile(step: s),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

enum _StepState { done, active, pending }

class _StepData {
  const _StepData({
    required this.state,
    required this.title,
    required this.detail,
    this.index,
    this.path,
  });

  final _StepState state;
  final String title;
  final String detail;
  final int? index;
  final String? path;
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});

  final _StepData step;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tile,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepNumber(step: step),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  step.detail,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.text3,
                  ),
                ),
                if (step.path != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      step.path!,
                      style: AppTypography.mono.copyWith(
                        color: AppColors.accent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepNumber extends StatelessWidget {
  const _StepNumber({required this.step});
  final _StepData step;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, child) = switch (step.state) {
      _StepState.done => (
          AppColors.success,
          Colors.black,
          const Icon(Icons.check_rounded, size: 14, color: Colors.black),
        ),
      _StepState.active => (
          AppColors.accent,
          Colors.black,
          Text(
            '${step.index ?? ''}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.black,
              fontFamilyFallback: AppTypography.monoFontFallback,
            ),
          ),
        ),
      _StepState.pending => (
          AppColors.surface3,
          AppColors.text2,
          Text(
            '${step.index ?? ''}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.text2,
              fontFamilyFallback: AppTypography.monoFontFallback,
            ),
          ),
        ),
    };
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: DefaultTextStyle(
        style: TextStyle(color: fg),
        child: child,
      ),
    );
  }
}

class _ScanIndicator extends StatelessWidget {
  const _ScanIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tile,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.accent,
              backgroundColor: AppColors.surface3,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            '正在扫描附近相机…',
            style: TextStyle(color: AppColors.text2, fontSize: 12),
          ),
          const Spacer(),
          Text(
            '0:12',
            style: AppTypography.mono.copyWith(
              color: AppColors.text4,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
