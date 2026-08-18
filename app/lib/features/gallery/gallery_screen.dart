import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/pill_button.dart';

/// Screen 7 — Gallery grid of camera-side objects. Thumbnails come from
/// `GetThumb` (fast) with a `GetLargeThumb` prefetch on tap.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final Set<int> _selected = {0, 1, 2, 3};
  int _activeSlot = 0;
  String _activeFilter = 'ALL';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Nikon Z8 · 图库', style: TextStyle(fontSize: 16)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          _StorageTabs(
            active: _activeSlot,
            onChange: (i) => setState(() => _activeSlot = i),
          ),
          _FilterChips(
            active: _activeFilter,
            onChange: (f) => setState(() => _activeFilter = f),
          ),
          Expanded(
            child: _ThumbGrid(
              selected: _selected,
              onToggle: (i) => setState(() {
                _selected.contains(i)
                    ? _selected.remove(i)
                    : _selected.add(i);
              }),
            ),
          ),
          _SelectionBar(
            count: _selected.length,
            sizeLabel: '82.4 MB',
            onSelectAll: () {},
            onDownload: () => context.push('/gallery/transfers'),
          ),
        ],
      ),
    );
  }
}

class _StorageTabs extends StatelessWidget {
  const _StorageTabs({required this.active, required this.onChange});
  final int active;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    const slots = [
      ('SLOT 1 · CFexpress', '128G / 76G 剩余'),
      ('SLOT 2 · SD', '64G / 22G'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < slots.length; i++)
            _tab(slots[i].$1, slots[i].$2, i == active, () => onChange(i)),
        ],
      ),
    );
  }

  Widget _tab(String label, String free, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? AppColors.text : AppColors.text3,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                free,
                style: AppTypography.mono.copyWith(
                  fontSize: 10,
                  color: AppColors.text4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.active, required this.onChange});
  final String active;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    const filters = [
      ('ALL', '全部', '348'),
      ('JPG', 'JPG', '142'),
      ('RAW', 'RAW', '142'),
      ('MP4', 'MP4', '64'),
      ('TODAY', '今天', '28'),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _chip(f.$1, f.$2, f.$3, f.$1 == active,
                  () => onChange(f.$1)),
            ),
        ],
      ),
    );
  }

  Widget _chip(String key, String label, String count, bool active,
      VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.accentSubtle : AppColors.surface,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: active ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? AppColors.accent : AppColors.text2,
                fontFamilyFallback: AppTypography.monoFontFallback,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              count,
              style: TextStyle(
                fontSize: 10,
                color: (active ? AppColors.accent : AppColors.text2)
                    .withOpacity(0.7),
                fontFamilyFallback: AppTypography.monoFontFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbGrid extends StatelessWidget {
  const _ThumbGrid({required this.selected, required this.onToggle});

  final Set<int> selected;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: 24,
      itemBuilder: (context, i) {
        final isNew = i < 4;
        final isRaw = i.isOdd;
        final isVideo = i == 6 || i == 15;
        return _Thumb(
          index: i,
          isNew: isNew,
          isRaw: isRaw,
          isVideo: isVideo,
          selected: selected.contains(i),
          onTap: () => onToggle(i),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.index,
    required this.isNew,
    required this.isRaw,
    required this.isVideo,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final bool isNew;
  final bool isRaw;
  final bool isVideo;
  final bool selected;
  final VoidCallback onTap;

  static const _palettes = <List<Color>>[
    [Color(0xFFD4A373), Color(0xFF6F4425), Color(0xFF1E1410)],
    [Color(0xFFCFA88A), Color(0xFF7A5E3D)],
    [Color(0xFFF0E0C0), Color(0xFF7A5C40), Color(0xFF2A1F16)],
    [Color(0xFF2E2018), Color(0xFF5C3A20), Color(0xFFD4A373)],
    [Color(0xFFEA8C60), Color(0xFFA0402A)],
    [Color(0xFF322820), Color(0xFF6A4A30), Color(0xFFD0B088)],
    [Color(0xFFFFC088), Color(0xFFA86338), Color(0xFF402015)],
    [Color(0xFF1A1410), Color(0xFF4A3220), Color(0xFF886040)],
  ];

  @override
  Widget build(BuildContext context) {
    final palette = _palettes[index % _palettes.length];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.2, -0.2),
                colors: palette,
              ),
            ),
          ),
          if (isNew && !selected)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent, width: 2),
              ),
            ),
          if (isVideo)
            const _VideoOverlay(duration: '0:12'),
          if (isRaw)
            Positioned(
              top: 3,
              left: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  'RAW',
                  style: AppTypography.mono.copyWith(
                    fontSize: 8,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (selected) ...[
            Container(color: AppColors.accent.withOpacity(0.15)),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
              ),
            ),
            const Positioned(
              top: 4,
              right: 4,
              child: _SelectionTick(),
            ),
          ],
        ],
      ),
    );
  }
}

class _VideoOverlay extends StatelessWidget {
  const _VideoOverlay({required this.duration});
  final String duration;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                stops: const [0.65, 1.0],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 3,
          right: 4,
          child: Text(
            duration,
            style: AppTypography.mono.copyWith(
              fontSize: 9,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

class _SelectionTick extends StatelessWidget {
  const _SelectionTick();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: const BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check_rounded, size: 12, color: Colors.black),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.sizeLabel,
    required this.onSelectAll,
    required this.onDownload,
  });

  final int count;
  final String sizeLabel;
  final VoidCallback onSelectAll;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(color: AppColors.text2, fontSize: 13),
                children: [
                  const TextSpan(text: '已选 '),
                  TextSpan(
                    text: '$count',
                    style: AppTypography.mono.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: sizeLabel,
                    style: AppTypography.mono.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          PillButton(
            label: '全选',
            variant: PillButtonVariant.ghost,
            onPressed: onSelectAll,
          ),
          const SizedBox(width: 8),
          PillButton(label: '下载', onPressed: onDownload),
        ],
      ),
    );
  }
}
