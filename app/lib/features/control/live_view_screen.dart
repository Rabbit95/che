import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../router.dart';
import '../../shared/providers/camera_control_provider.dart';
import '../../shared/providers/camera_properties_provider.dart';
import '../../shared/providers/connection_providers.dart';
import '../../shared/providers/live_view_provider.dart';
import '../../shared/theme/app_theme.dart';
import 'widgets/exposure_bar.dart';
import 'widgets/live_view_hud.dart';
import 'widgets/lv_scene.dart';
import 'widgets/mode_toggle.dart';
import 'widgets/shutter_button.dart';

/// Screens 4 + 5 — Live View (photo mode) and (video recording) share
/// one widget; toggle switches HUD, waveform/histogram, and shutter chrome.
class LiveViewScreen extends ConsumerStatefulWidget {
  const LiveViewScreen({super.key});

  @override
  ConsumerState<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends ConsumerState<LiveViewScreen> {
  CaptureMode _mode = CaptureMode.photo;
  bool _recording = false;
  Duration _recElapsed = Duration.zero;
  DriveMode _drive = DriveMode.burst;

  /// True from the moment the user releases the shutter until
  /// InitiateCapture + DeviceReady round-trip resolves. Used to grey out
  /// the button so a nervous tap doesn't fire a second exposure.
  bool _busy = false;

  /// Reference-time anchor for the recording clock. Set on
  /// startMovieRecording ack, nulled on stop. We derive `_recElapsed`
  /// from `now - _recStartedAt` rather than counting ticks so a stalled
  /// timer can't drift the reading.
  DateTime? _recStartedAt;
  Timer? _recTimer;

  @override
  void dispose() {
    _recTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If the active connection disappears (unplug, cable pull, app-level
    // close), bounce back to the discovery screen so the user isn't left
    // staring at a dead LV surface.
    ref.listen<ActiveConnection?>(activeConnectionProvider, (prev, next) {
      if (prev != null && next == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('相机已断开')),
        );
        context.go(AppRoute.discovery);
      }
    });

    final active = ref.watch(activeConnectionProvider);
    final commands = ref.watch(cameraCommandsProvider);
    final propsSnapshot =
        ref.watch(cameraPropertiesProvider).valueOrNull ??
            CameraPropertySnapshot.empty;
    final lvState = ref.watch(liveViewProvider).value ?? LiveViewState.idle;

    final canShoot = commands != null && !_busy;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const LvScene(),
                  const _RuleOfThirdsGrid(),
                  LiveViewHud(
                    mode: _mode,
                    recording: _recording,
                    channel: active?.camera.channel ?? TransportChannel.usb,
                    fps: lvState.measuredFps,
                    cameraName: active?.deviceInfo.model ?? 'Nikon Z',
                    recElapsed: _recElapsed,
                    onTapFocus: (Offset position, Size widgetSize) =>
                        _handleTapFocus(position, widgetSize, lvState.frame),
                  ),
                ],
              ),
            ),
            _LvControls(
              mode: _mode,
              drive: _drive,
              recording: _recording,
              shutterEnabled: canShoot,
              values: _buildExposureValues(propsSnapshot, isVideo: _mode == CaptureMode.video),
              onModeChanged: (m) {
                // Never let the user flip modes while a recording is live.
                // Stop-then-flip would race the movie-rec state.
                if (_recording) return;
                setState(() => _mode = m);
              },
              onDriveChanged: (d) => setState(() => _drive = d),
              onShutterTap: canShoot ? _shutterTap : () {},
              onOpenParameters: () => context.push(AppRoute.parameters),
            ),
          ],
        ),
      ),
    );
  }

  /// Compose the [ExposureValues] rendered in the bottom pill row from
  /// the current property snapshot. Missing props render as an em dash
  /// so the strip stays five slots wide even during a partial read.
  ExposureValues _buildExposureValues(
    CameraPropertySnapshot snapshot, {
    required bool isVideo,
  }) {
    String read(int code) => snapshot[code]?.formattedValue ?? '—';
    final isoStr = read(StandardPropCode.exposureIndex);
    // "Hot" flag lights the ISO pill amber when the value crosses 1600 —
    // signals the shooter that noise will start showing. Cheap heuristic;
    // safe to skip when we don't have a numeric value.
    final isoInt = int.tryParse(isoStr);
    final isoHot = isoInt != null && isoInt >= 1600;
    return ExposureValues(
      iso: isoStr,
      shutter: read(StandardPropCode.exposureTime),
      aperture: read(StandardPropCode.fNumber),
      ev: read(StandardPropCode.exposureBiasCompensation),
      wb: read(StandardPropCode.whiteBalance),
      isoHot: isoHot,
    );
  }

  Future<void> _shutterTap() async {
    final commands = ref.read(cameraCommandsProvider);
    if (commands == null || _busy) return;

    if (_mode == CaptureMode.video) {
      await _toggleRecording(commands);
      return;
    }

    // Photo: fire InitiateCaptureRecInMedia + DeviceReady.
    setState(() => _busy = true);
    unawaited(HapticFeedback.mediumImpact());
    try {
      await commands.capture();
      if (!mounted) return;
      unawaited(HapticFeedback.selectionClick());
      _showSnack('已拍摄', tone: _SnackTone.success);
    } on CameraControlFailure catch (e) {
      if (!mounted) return;
      _showSnack(e.userMessage, tone: _SnackTone.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Translate a screen-space tap on the LV surface into a
  /// `ChangeAfArea + AfDrive` call. The LV widget renders the frame
  /// letterboxed inside its parent, so we map the tap through the
  /// frame's real pixel dimensions when they're known; otherwise fall
  /// back to a normalized 1000×1000 grid, which Nikon bodies accept.
  Future<void> _handleTapFocus(
    Offset position,
    Size widgetSize,
    LiveViewFrame? frame,
  ) async {
    final client = ref.read(activeConnectionProvider)?.client;
    if (client == null) return;
    if (widgetSize.width <= 0 || widgetSize.height <= 0) return;

    final int frameW = frame?.header.imageWidth ?? 1000;
    final int frameH = frame?.header.imageHeight ?? 1000;

    final xNorm = (position.dx / widgetSize.width).clamp(0.0, 1.0);
    final yNorm = (position.dy / widgetSize.height).clamp(0.0, 1.0);
    final x = (xNorm * frameW).round();
    final y = (yNorm * frameH).round();

    unawaited(HapticFeedback.selectionClick());
    try {
      await client.tapToFocus(x, y);
    } on PtpResponseException catch (e) {
      if (!mounted) return;
      _showSnack('对焦失败: ${e.codeLabel}', tone: _SnackTone.error);
    }
  }

  Future<void> _toggleRecording(CameraCommands commands) async {
    setState(() => _busy = true);
    unawaited(HapticFeedback.heavyImpact());
    try {
      if (_recording) {
        await commands.stopMovieRecording();
        _recTimer?.cancel();
        _recTimer = null;
        _recStartedAt = null;
        if (!mounted) return;
        setState(() {
          _recording = false;
          _recElapsed = Duration.zero;
        });
      } else {
        await commands.startMovieRecording();
        if (!mounted) return;
        final now = DateTime.timestamp();
        setState(() {
          _recording = true;
          _recStartedAt = now;
          _recElapsed = Duration.zero;
        });
        // Redraw once per second — the HUD only shows seconds, so 100 ms
        // ticks would burn frames for nothing.
        _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted || _recStartedAt == null) return;
          setState(() {
            _recElapsed = DateTime.timestamp().difference(_recStartedAt!);
          });
        });
      }
    } on CameraControlFailure catch (e) {
      if (!mounted) return;
      _showSnack(e.userMessage, tone: _SnackTone.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message, {required _SnackTone tone}) {
    final color = switch (tone) {
      _SnackTone.success => AppColors.accent,
      _SnackTone.error => AppColors.record,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
          duration: tone == _SnackTone.error
              ? const Duration(seconds: 4)
              : const Duration(milliseconds: 900),
        ),
      );
  }
}

enum _SnackTone { success, error }

class _RuleOfThirdsGrid extends StatelessWidget {
  const _RuleOfThirdsGrid();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
        size: Size.infinite,
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 1;
    // Horizontal thirds
    for (var i = 1; i < 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LvControls extends StatelessWidget {
  const _LvControls({
    required this.mode,
    required this.drive,
    required this.recording,
    required this.shutterEnabled,
    required this.values,
    required this.onModeChanged,
    required this.onDriveChanged,
    required this.onShutterTap,
    required this.onOpenParameters,
  });

  final CaptureMode mode;
  final DriveMode drive;
  final bool recording;
  final bool shutterEnabled;
  final ExposureValues values;
  final ValueChanged<CaptureMode> onModeChanged;
  final ValueChanged<DriveMode> onDriveChanged;
  final VoidCallback onShutterTap;
  final VoidCallback onOpenParameters;

  @override
  Widget build(BuildContext context) {
    final isVideo = mode == CaptureMode.video;
    return Container(
      color: Colors.black.withOpacity(0.75),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        8 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        children: [
          ExposureBar(
            onTap: onOpenParameters,
            values: values,
          ),
          const SizedBox(height: 12),
          // Layout: [SideTool] [ModeToggle] [Shutter] [ModeToggle] [SideTool]
          // Intrinsic width ≈ 356px on a 328px screen. Wrap the two toggles
          // in Flexible + FittedBox so they scale down proportionally on
          // narrow devices instead of overflowing.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SideTool(
                icon: isVideo ? Icons.check_circle_outline : Icons.crop_original,
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: ModeToggle<CaptureMode>(
                    options: const [
                      ModeToggleOption(value: CaptureMode.photo, label: '照片'),
                      ModeToggleOption(value: CaptureMode.video, label: '视频'),
                    ],
                    current: mode,
                    onChanged: onModeChanged,
                  ),
                ),
              ),
              Opacity(
                opacity: shutterEnabled ? 1.0 : 0.5,
                child: ShutterButton(
                  mode: mode,
                  recording: recording,
                  onTap: onShutterTap,
                ),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: ModeToggle<DriveMode>(
                    options: isVideo
                        ? const [
                            ModeToggleOption(value: DriveMode.burst, label: '4K60'),
                            ModeToggleOption(value: DriveMode.single, label: 'FHD'),
                          ]
                        : const [
                            ModeToggleOption(value: DriveMode.burst, label: '连拍'),
                            ModeToggleOption(value: DriveMode.single, label: '单张'),
                          ],
                    current: drive,
                    onChanged: onDriveChanged,
                  ),
                ),
              ),
              const _SideTool(icon: Icons.photo_library_outlined),
            ],
          ),
        ],
      ),
    );
  }
}

class _SideTool extends StatelessWidget {
  const _SideTool({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Icon(icon, color: AppColors.text2, size: 20),
    );
  }
}
