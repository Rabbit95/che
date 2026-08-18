import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import '../../shared/providers/camera_control_provider.dart';
import '../../shared/providers/camera_properties_provider.dart';
import '../../shared/providers/connection_providers.dart';
import '../../shared/theme/app_theme.dart';
import 'widgets/lv_scene.dart';

/// Screen 6 — bottom-sheet parameter picker. Slides up over a blurred
/// live view. Reads `cameraPropertiesProvider` for live values; writes
/// (SetDevicePropValue) go through [CameraCommands.setProperty].
class ParameterSheetScreen extends StatelessWidget {
  const ParameterSheetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const LvScene(),
          Container(color: Colors.black.withOpacity(0.5)),
          const Align(
            alignment: Alignment.bottomCenter,
            child: _ParameterSheet(),
          ),
        ],
      ),
    );
  }
}

class _ParameterSheet extends ConsumerWidget {
  const _ParameterSheet();

  /// The prop the wheel-preview head is anchored to. First entry with a
  /// non-null value wins — usually ISO on a body with the mode dial set
  /// to M/A/S. Falls back to shutter and then aperture if ISO is missing.
  static const List<int> _wheelPreference = <int>[
    StandardPropCode.exposureIndex,
    StandardPropCode.exposureTime,
    StandardPropCode.fNumber,
  ];

  /// Ordered list of props shown as rows. Icons are picked to roughly
  /// match the on-body indicator glyphs.
  static const List<_ParamRowSpec> _rowSpecs = <_ParamRowSpec>[
    _ParamRowSpec(propCode: StandardPropCode.exposureIndex, icon: Icons.iso),
    _ParamRowSpec(
      propCode: StandardPropCode.exposureTime,
      icon: Icons.shutter_speed_outlined,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.fNumber,
      icon: Icons.camera_outlined,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.exposureBiasCompensation,
      icon: Icons.exposure,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.whiteBalance,
      icon: Icons.wb_auto_outlined,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.focusMode,
      icon: Icons.center_focus_strong_outlined,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.exposureProgramMode,
      icon: Icons.tune,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.stillCaptureMode,
      icon: Icons.burst_mode_outlined,
    ),
    _ParamRowSpec(
      propCode: StandardPropCode.batteryLevel,
      icon: Icons.battery_full,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConnected = ref.watch(activeConnectionProvider) != null;
    final propsAsync = ref.watch(cameraPropertiesProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollCtl) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.sheet,
            boxShadow: [
              BoxShadow(
                color: Color(0x66000000),
                offset: Offset(0, -20),
                blurRadius: 40,
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.surface3,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '相机参数',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => context.pop(),
                    ),
                  ],
                ),
              ),
              _WheelPreview(
                snapshot: propsAsync.valueOrNull,
                preference: _wheelPreference,
              ),
              const SizedBox(height: 4),
              Text(
                _wheelCaption(propsAsync.valueOrNull, _wheelPreference),
                style: AppTypography.mono.copyWith(
                  color: AppColors.text3,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _buildBody(
                  scrollCtl: scrollCtl,
                  propsAsync: propsAsync,
                  isConnected: isConnected,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody({
    required ScrollController scrollCtl,
    required AsyncValue<CameraPropertySnapshot> propsAsync,
    required bool isConnected,
  }) {
    if (!isConnected) {
      return const _SheetPlaceholder(
        icon: Icons.link_off_outlined,
        message: '未连接相机',
        detail: '返回发现界面选择一台相机后再来调参',
      );
    }
    return propsAsync.when(
      loading: () => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (err, _) => _SheetPlaceholder(
        icon: Icons.error_outline,
        message: '读取参数失败',
        detail: err.toString(),
      ),
      data: (snapshot) {
        if (snapshot.byCode.isEmpty) {
          return const _SheetPlaceholder(
            icon: Icons.hourglass_bottom,
            message: '相机未暴露任何参数',
            detail: '相机当前 USB 模式可能不允许控制器读取属性',
          );
        }
        return ListView(
          controller: scrollCtl,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            for (final spec in _rowSpecs)
              if (snapshot[spec.propCode] != null)
                _ParamRow(
                  icon: spec.icon,
                  view: snapshot[spec.propCode]!,
                ),
          ],
        );
      },
    );
  }

  static String _wheelCaption(
    CameraPropertySnapshot? snapshot,
    List<int> pref,
  ) {
    if (snapshot == null) return '连接中';
    final anchor = _wheelAnchor(snapshot, pref);
    if (anchor == null) return '暂无可显示的参数';
    final anchorView = snapshot[anchor]!;
    return '${anchorView.label} · 拖动或点击具体档位';
  }

  static int? _wheelAnchor(CameraPropertySnapshot snapshot, List<int> pref) {
    for (final code in pref) {
      final view = snapshot[code];
      if (view != null) return code;
    }
    if (snapshot.byCode.isNotEmpty) return snapshot.byCode.keys.first;
    return null;
  }
}

class _ParamRowSpec {
  const _ParamRowSpec({required this.propCode, required this.icon});
  final int propCode;
  final IconData icon;
}

class _WheelPreview extends StatelessWidget {
  const _WheelPreview({required this.snapshot, required this.preference});

  final CameraPropertySnapshot? snapshot;
  final List<int> preference;

  @override
  Widget build(BuildContext context) {
    final values = _wheelValues();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        for (var i = 0; i < values.length; i++)
          _WheelValue(text: values[i], center: i == values.length ~/ 2),
      ],
    );
  }

  /// Build a 5-item wheel — the centre entry is the camera's current
  /// value, flanked by the two enum entries above and below (or a
  /// placeholder dash when no enum context is available).
  List<String> _wheelValues() {
    final snap = snapshot;
    if (snap == null || snap.byCode.isEmpty) {
      return const ['—', '—', '—', '—', '—'];
    }
    int? anchor;
    for (final code in preference) {
      if (snap[code] != null) {
        anchor = code;
        break;
      }
    }
    anchor ??= snap.byCode.keys.first;
    final view = snap[anchor]!;
    final current = view.formattedValue;

    if (view.desc.form case EnumForm(:final values)) {
      final currentIndex = values.indexOf(view.desc.currentValue as Object);
      if (currentIndex == -1) {
        return ['—', '—', current, '—', '—'];
      }
      String at(int i) {
        if (i < 0 || i >= values.length) return '—';
        return PropFormatter.formatValue(view.propCode, values[i]);
      }
      return [
        at(currentIndex - 2),
        at(currentIndex - 1),
        current,
        at(currentIndex + 1),
        at(currentIndex + 2),
      ];
    }
    return ['—', '—', current, '—', '—'];
  }
}

class _WheelValue extends StatelessWidget {
  const _WheelValue({required this.text, required this.center});
  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: center ? AppColors.accentSubtle : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: center ? 22 : 13,
            fontWeight: FontWeight.w600,
            color: center ? AppColors.accent : AppColors.text4,
            fontFamilyFallback: AppTypography.monoFontFallback,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _ParamRow extends ConsumerStatefulWidget {
  const _ParamRow({required this.icon, required this.view});

  final IconData icon;
  final CameraPropertyView view;

  @override
  ConsumerState<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends ConsumerState<_ParamRow> {
  /// True while a SetDevicePropValue → DeviceReady round-trip is
  /// in flight. Locks the row so the user can't fire a second write
  /// before the first one lands.
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final canWrite = view.isWritable && _pickerFor(view) != null;
    return InkWell(
      onTap: canWrite && !_pending ? _openPicker : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Icon(widget.icon, size: 18, color: AppColors.text3),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                view.longName,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.text,
                ),
              ),
            ),
            if (!canWrite)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.lock_outline,
                  size: 12,
                  color: AppColors.text4,
                ),
              ),
            if (_pending)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.accent,
                  ),
                ),
              ),
            Text(
              view.formattedValue,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                fontFamilyFallback: AppTypography.monoFontFallback,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              canWrite ? Icons.chevron_right : Icons.remove_circle_outline,
              size: 16,
              color: canWrite ? AppColors.text3 : AppColors.text4,
            ),
          ],
        ),
      ),
    );
  }

  /// Determine what kind of picker (if any) this row should show. We
  /// support enum-form and range-form for numeric types; anything else
  /// stays read-only for now.
  static _PickerKind? _pickerFor(CameraPropertyView view) {
    final form = view.desc.form;
    if (form is EnumForm && form.values.isNotEmpty) return _PickerKind.enumList;
    if (form is RangeForm) return _PickerKind.range;
    return null;
  }

  Future<void> _openPicker() async {
    final commands = ref.read(cameraCommandsProvider);
    if (commands == null) return;

    final view = widget.view;
    final kind = _pickerFor(view);
    if (kind == null) return;

    // Kick the modal off synchronously so `context` is used before any
    // await — keeps `use_build_context_synchronously` quiet without an
    // `if (mounted)` guard that would be dead code at this point.
    final Future<Object?> pickerFuture = switch (kind) {
      _PickerKind.enumList => _showEnumPicker(context, view),
      _PickerKind.range => _showRangePicker(context, view),
    };
    final picked = await pickerFuture;
    if (picked == null) return;
    if (picked == view.desc.currentValue) return; // no-op

    await _applyWrite(commands, picked);
  }

  Future<void> _applyWrite(CameraCommands commands, Object value) async {
    setState(() => _pending = true);
    try {
      await commands.setProperty(
        widget.view.propCode,
        widget.view.desc.dataType,
        value,
        actionLabel: '写入 ${widget.view.longName} 失败',
      );
      if (!mounted) return;
      _showSnack('已写入 ${widget.view.longName}: '
          '${PropFormatter.formatValue(widget.view.propCode, value)}');
    } on CameraControlFailure catch (e) {
      if (!mounted) return;
      _showSnack(e.userMessage, isError: true);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? AppColors.record : AppColors.accent,
          behavior: SnackBarBehavior.floating,
          duration: isError
              ? const Duration(seconds: 4)
              : const Duration(milliseconds: 900),
        ),
      );
  }
}

enum _PickerKind { enumList, range }

/// Enum picker — modal bottom sheet with a scrollable list of every
/// legal value from [EnumForm.values]. Highlights the current selection.
Future<Object?> _showEnumPicker(
  BuildContext context,
  CameraPropertyView view,
) {
  final form = view.desc.form as EnumForm;
  final current = view.desc.currentValue;
  return showModalBottomSheet<Object>(
    context: context,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheet),
    builder: (ctx) {
      // Auto-scroll to centre the currently selected value.
      final currentIndex = form.values.indexOf(current as Object);
      final controller = ScrollController(
        initialScrollOffset:
            currentIndex > 0 ? (currentIndex * 48.0 - 120).clamp(0, 1e6) : 0,
      );
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: AppColors.surface3,
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择 ${view.longName}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                controller: controller,
                shrinkWrap: true,
                itemCount: form.values.length,
                itemBuilder: (_, i) {
                  final value = form.values[i];
                  final selected = value == current;
                  final label = PropFormatter.formatValue(view.propCode, value);
                  return InkWell(
                    onTap: () => Navigator.of(ctx).pop(value),
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected
                                    ? AppColors.accent
                                    : AppColors.text,
                                fontFamilyFallback: AppTypography.monoFontFallback,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          if (selected)
                            const Icon(
                              Icons.check_rounded,
                              color: AppColors.accent,
                              size: 18,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// Range picker — slider from min to max, snapping to `step`. Only
/// covers int-valued props (the vast majority — EV/focus distance in
/// hundredths, etc.). Returns the integer value chosen, or null on cancel.
Future<Object?> _showRangePicker(
  BuildContext context,
  CameraPropertyView view,
) {
  final form = view.desc.form as RangeForm;
  final min = form.min;
  final max = form.max;
  final step = form.step;
  final current = view.desc.currentValue;

  if (min is! int || max is! int || step is! int || current is! int) {
    // Non-int ranges are rare on Nikon and we don't format them yet.
    // Bail rather than pretend we can offer a working picker.
    return Future<Object?>.value(null);
  }
  if (max <= min) return Future<Object?>.value(null);

  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheet),
    builder: (ctx) => _RangeSheet(
      view: view,
      min: min,
      max: max,
      step: step == 0 ? 1 : step,
      current: current,
    ),
  );
}

class _RangeSheet extends StatefulWidget {
  const _RangeSheet({
    required this.view,
    required this.min,
    required this.max,
    required this.step,
    required this.current,
  });

  final CameraPropertyView view;
  final int min;
  final int max;
  final int step;
  final int current;

  @override
  State<_RangeSheet> createState() => _RangeSheetState();
}

class _RangeSheetState extends State<_RangeSheet> {
  late int _value = widget.current.clamp(widget.min, widget.max);

  @override
  Widget build(BuildContext context) {
    // Slider needs the value snapped to step for `divisions` to line up.
    final span = widget.max - widget.min;
    final divisions = (span / widget.step).round();
    final snapped = _snap(_value);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: AppColors.surface3,
              borderRadius: BorderRadius.circular(100),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '调整 ${widget.view.longName}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  PropFormatter.formatValue(widget.view.propCode, snapped),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Slider(
              min: widget.min.toDouble(),
              max: widget.max.toDouble(),
              divisions: divisions > 0 ? divisions : null,
              value: snapped.toDouble(),
              onChanged: (v) => setState(() => _value = _snap(v.round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(snapped),
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _snap(int v) {
    final rel = v - widget.min;
    final steps = (rel / widget.step).round();
    final snapped = widget.min + steps * widget.step;
    return snapped.clamp(widget.min, widget.max);
  }
}

class _SheetPlaceholder extends StatelessWidget {
  const _SheetPlaceholder({
    required this.icon,
    required this.message,
    this.detail,
  });

  final IconData icon;
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.text3),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.text2,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: AppTypography.mono.copyWith(
                  fontSize: 11,
                  color: AppColors.text3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
