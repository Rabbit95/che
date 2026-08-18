import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';

/// Screen 8 — Transfer queue. Shows global progress + per-item status.
///
/// The real progress source is a per-object stream built on top of
/// `NikonZClient.downloadObject(handle, totalSize)` — the UI here mirrors
/// the mockup with static demo data.
class TransferQueueScreen extends StatelessWidget {
  const TransferQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('正在下载', style: TextStyle(fontSize: 16)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.pause_rounded),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          const _TransferHero(),
          const Expanded(child: _TransferList()),
        ],
      ),
    );
  }
}

class _TransferHero extends StatelessWidget {
  const _TransferHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x0FE8B455), Colors.transparent],
        ),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: AppTypography.monoStatLarge,
                    children: [
                      const TextSpan(text: '4 '),
                      TextSpan(
                        text: '/ 24',
                        style: TextStyle(
                          color: AppColors.text3,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          fontFamilyFallback:
                              AppTypography.monoFontFallback,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '18.4 MB/s · USB 3.2',
                    style: AppTypography.mono.copyWith(
                      color: AppColors.success,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '预计剩余 2:14',
                    style: AppTypography.mono.copyWith(
                      color: AppColors.text3,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _Progress(fraction: 0.17),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '317 MB / 1.82 GB',
                style: AppTypography.mono.copyWith(
                  color: AppColors.text3,
                  fontSize: 11,
                ),
              ),
              RichText(
                text: TextSpan(
                  style: AppTypography.mono.copyWith(
                    color: AppColors.text3,
                    fontSize: 11,
                  ),
                  children: const [
                    TextSpan(text: '存到 · '),
                    TextSpan(
                      text: '系统相册',
                      style: TextStyle(color: AppColors.accent),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: SizedBox(
        height: 6,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: AppColors.surface2),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [AppColors.accent, Color(0xFFFFCF78)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withOpacity(0.4),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferList extends StatelessWidget {
  const _TransferList();

  @override
  Widget build(BuildContext context) {
    const items = <_XferItem>[
      _XferItem(
        name: 'DSC_2841.NEF',
        size: '42.6 MB',
        status: 'chunk 128 / 174',
        percentLabel: '73%',
        progress: 0.73,
        state: _XferState.active,
      ),
      _XferItem(
        name: 'DSC_2841.JPG',
        size: '8.2 MB',
        status: '队列中',
        percentLabel: '—',
        progress: 0.0,
        state: _XferState.wait,
      ),
      _XferItem(
        name: 'DSC_2842.NEF',
        size: '44.1 MB',
        status: '队列中',
        percentLabel: '—',
        progress: 0.0,
        state: _XferState.wait,
      ),
      _XferItem(
        name: 'DSC_2840.NEF',
        size: '40.8 MB',
        status: '已完成',
        percentLabel: '已存入相册',
        progress: 1.0,
        state: _XferState.done,
      ),
      _XferItem(
        name: 'DSC_2840.JPG',
        size: '7.4 MB',
        status: '已完成',
        percentLabel: '已存入相册',
        progress: 1.0,
        state: _XferState.done,
      ),
      _XferItem(
        name: 'DSC_2839.MOV',
        size: '218 MB',
        status: '已完成',
        percentLabel: '已存入相册',
        progress: 1.0,
        state: _XferState.done,
      ),
    ];
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) => _XferRow(item: items[i]),
    );
  }
}

enum _XferState { active, wait, done }

class _XferItem {
  const _XferItem({
    required this.name,
    required this.size,
    required this.status,
    required this.percentLabel,
    required this.progress,
    required this.state,
  });

  final String name;
  final String size;
  final String status;
  final String percentLabel;
  final double progress;
  final _XferState state;
}

class _XferRow extends StatelessWidget {
  const _XferRow({required this.item});
  final _XferItem item;

  @override
  Widget build(BuildContext context) {
    final subColor =
        item.state == _XferState.done ? AppColors.success : AppColors.text3;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(6),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF6F4425),
                  Colors.black.withOpacity(0.6),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      item.name,
                      style: AppTypography.mono.copyWith(
                        color: AppColors.text,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      item.size,
                      style: AppTypography.mono.copyWith(
                        color: AppColors.text3,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      item.status,
                      style: AppTypography.mono.copyWith(
                        color: subColor,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      item.percentLabel,
                      style: AppTypography.mono.copyWith(
                        color: subColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                if (item.state == _XferState.active) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(color: AppColors.surface2),
                          FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: item.progress,
                            child: Container(color: AppColors.accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _statusIcon(),
        ],
      ),
    );
  }

  Widget _statusIcon() {
    return SizedBox(
      width: 24,
      height: 24,
      child: switch (item.state) {
        _XferState.active =>
          const Icon(Icons.download_rounded, color: AppColors.text3, size: 20),
        _XferState.wait =>
          const Icon(Icons.schedule_rounded, color: AppColors.text4, size: 18),
        _XferState.done =>
          const Icon(Icons.check_rounded, color: AppColors.success, size: 20),
      },
    );
  }
}
