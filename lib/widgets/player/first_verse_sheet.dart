import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../core/utils/verse_detector.dart';
import '../../providers/player_provider.dart';

/// 1番シートの結果: この範囲で覚える / 自動に戻す
sealed class FirstVerseResult {
  const FirstVerseResult();
}

class FirstVerseSave extends FirstVerseResult {
  const FirstVerseSave(this.endMs);
  final int endMs;
}

class FirstVerseReset extends FirstVerseResult {
  const FirstVerseReset();
}

/// 「1番」ボタンの長押しで出すシート。今の曲の 1 番の終わりを波形の上で直す
/// （押す・横に動かすとその位置。±1 秒、今の再生位置）。
/// 自動で探す範囲（全曲共通の設定）もここで変えられる。
/// 始まり（A）は今の値のまま（手で直した始まりがあればそれ、無ければ曲の頭）
class FirstVerseSheet extends ConsumerStatefulWidget {
  const FirstVerseSheet({
    super.key,
    required this.title,
    required this.waveform,
    required this.durationMs,
    required this.startMs,
    required this.manualEndMs,
    required this.positionMs,
  });

  final String title;
  final List<double>? waveform;
  final int durationMs;
  final int startMs;

  /// 手で直した終わり（null なら自動）
  final int? manualEndMs;

  /// 今の再生位置（「今の位置」ボタン用）
  final int positionMs;

  static Future<FirstVerseResult?> show(
    BuildContext context, {
    required String title,
    required List<double>? waveform,
    required int durationMs,
    required int startMs,
    required int? manualEndMs,
    required int positionMs,
  }) {
    return showModalBottomSheet<FirstVerseResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FirstVerseSheet(
        title: title,
        waveform: waveform,
        durationMs: durationMs,
        startMs: startMs,
        manualEndMs: manualEndMs,
        positionMs: positionMs,
      ),
    );
  }

  @override
  ConsumerState<FirstVerseSheet> createState() => _FirstVerseSheetState();
}

class _FirstVerseSheetState extends ConsumerState<FirstVerseSheet> {
  /// 手で動かしたか（動かしていなければ自動の値を出し続ける）
  late int? _editedEndMs = widget.manualEndMs;

  int _autoEndMs(VerseRange range) =>
      VerseDetector.findCutPoint(
        waveform: widget.waveform,
        durationMs: widget.durationMs,
        searchStartMs: range.startSec * 1000,
        searchEndMs: range.endSec * 1000,
      ) ??
      widget.durationMs;

  void _setEnd(int ms) {
    final lo = widget.startMs + 1000;
    setState(() => _editedEndMs = ms.clamp(min(lo, widget.durationMs), widget.durationMs));
  }

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(verseSearchRangeProvider);
    final endMs = _editedEndMs ?? _autoEndMs(range);
    final textTheme = Theme.of(context).textTheme;
    final manual = _editedEndMs != null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1番の範囲', style: textTheme.titleMedium),
            Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall
                    ?.copyWith(color: AppTheme.muted(context))),
            const SizedBox(height: AppSpacing.md),
            _VerseWaveform(
              waveform: widget.waveform,
              durationMs: widget.durationMs,
              startMs: widget.startMs,
              endMs: endMs,
              searchStartMs: range.startSec * 1000,
              searchEndMs: range.endSec * 1000,
              onSeek: _setEnd,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Text(
                  '${TimeUtils.formatShortMs(widget.startMs)} 〜 '
                  '${TimeUtils.formatShortMs(endMs)}',
                  style: textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(manual ? '手で直した範囲' : '自動',
                    style: textTheme.labelSmall?.copyWith(
                        color: manual
                            ? AppTheme.accentGreen
                            : AppTheme.muted(context))),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                OutlinedButton(
                  onPressed: () => _setEnd(endMs - 1000),
                  child: const Text('−1秒'),
                ),
                OutlinedButton(
                  onPressed: () => _setEnd(endMs + 1000),
                  child: const Text('+1秒'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.positionMs > widget.startMs
                      ? () => _setEnd(widget.positionMs)
                      : null,
                  icon: const Icon(Icons.my_location, size: AppIconSizes.s),
                  label: const Text('今の位置'),
                ),
              ],
            ),
            const Divider(height: AppSpacing.xl * 2),
            Row(
              children: [
                Expanded(
                  child: Text('自動で探す範囲',
                      style: textTheme.bodyMedium),
                ),
                VerseRangeFields(
                  range: range,
                  onChanged: (v) =>
                      ref.read(verseSearchRangeProvider.notifier).value = v,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                TextButton(
                  onPressed: widget.manualEndMs != null
                      ? () => Navigator.pop(context, const FirstVerseReset())
                      : null,
                  child: const Text('自動に戻す'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: manual
                      ? () => Navigator.pop(context, FirstVerseSave(endMs))
                      : null,
                  child: const Text('この範囲で覚える'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 設定の「1番を探す範囲」のダイアログ
class VerseRangeDialog {
  VerseRangeDialog._();

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => Consumer(
          builder: (ctx, ref, _) => AlertDialog(
            title: const Text('1番を探す範囲'),
            content: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                VerseRangeFields(
                  range: ref.watch(verseSearchRangeProvider),
                  onChanged: (v) =>
                      ref.read(verseSearchRangeProvider.notifier).value = v,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => ref.read(verseSearchRangeProvider.notifier).value =
                    VerseRangeNotifier.defaultRange,
                child: const Text('既定に戻す'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ),
      );
}

/// 自動で探す範囲の「始まり〜終わり」のプルダウン 2 つ（シートと設定で共用）。
/// 終わりは始まりより後の候補だけ
class VerseRangeFields extends StatelessWidget {
  const VerseRangeFields({
    super.key,
    required this.range,
    required this.onChanged,
  });

  final VerseRange range;
  final ValueChanged<VerseRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final starts = VerseRangeNotifier.startOptions;
    final ends = [
      for (final e in VerseRangeNotifier.endOptions)
        if (e > range.startSec) e,
    ];
    DropdownButton<int> drop(List<int> values, int value, ValueChanged<int> on) =>
        DropdownButton<int>(
          value: values.contains(value) ? value : null,
          isDense: true,
          items: [
            for (final v in values)
              DropdownMenuItem(
                  value: v, child: Text(VerseRangeNotifier.secLabel(v))),
          ],
          onChanged: (v) {
            if (v != null) on(v);
          },
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        drop(starts, range.startSec, (v) {
          // 始まりを終わり以降にしたら、終わりをその次の候補へ
          final end = range.endSec > v
              ? range.endSec
              : VerseRangeNotifier.endOptions.firstWhere((e) => e > v,
                  orElse: () => VerseRangeNotifier.endOptions.last);
          onChanged((startSec: v, endSec: end));
        }),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text('〜'),
        ),
        drop(ends, range.endSec,
            (v) => onChanged((startSec: range.startSec, endSec: v))),
      ],
    );
  }
}

/// 曲全体の波形に、1 番の範囲（明るく）・終わりの線・自動で探す範囲（下の帯）を描く。
/// 押す・横に動かすとその位置を終わりにする
class _VerseWaveform extends StatelessWidget {
  const _VerseWaveform({
    required this.waveform,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.searchStartMs,
    required this.searchEndMs,
    required this.onSeek,
  });

  final List<double>? waveform;
  final int durationMs;
  final int startMs;
  final int endMs;
  final int searchStartMs;
  final int searchEndMs;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      width: double.infinity,
      child: LayoutBuilder(builder: (context, c) {
        int toMs(double x) =>
            (x / c.maxWidth).clamp(0.0, 1.0) * durationMs ~/ 1;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => onSeek(toMs(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onSeek(toMs(d.localPosition.dx)),
          child: CustomPaint(
            painter: _VersePainter(
              waveform: waveform,
              durationMs: durationMs,
              startMs: startMs,
              endMs: endMs,
              searchStartMs: searchStartMs,
              searchEndMs: searchEndMs,
              base: AppTheme.muted(context, alpha: 0.35),
              accent: AppTheme.accentGreen,
              track: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
            ),
          ),
        );
      }),
    );
  }
}

class _VersePainter extends CustomPainter {
  _VersePainter({
    required this.waveform,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.searchStartMs,
    required this.searchEndMs,
    required this.base,
    required this.accent,
    required this.track,
  });

  final List<double>? waveform;
  final int durationMs;
  final int startMs;
  final int endMs;
  final int searchStartMs;
  final int searchEndMs;
  final Color base;
  final Color accent;
  final Color track;

  static const _bandH = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;
    final w = size.width;
    final waveH = size.height - _bandH - 4;
    double x(int ms) => ms / durationMs * w;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, w, waveH), const Radius.circular(8)),
      Paint()..color = track,
    );
    final data = waveform;
    if (data != null && data.isNotEmpty) {
      const step = 3.0;
      final mid = waveH / 2;
      for (var px = 0.0; px < w; px += step) {
        final i0 = (px / w * data.length).floor().clamp(0, data.length - 1);
        final i1 = ((px + step) / w * data.length).ceil().clamp(i0 + 1, data.length);
        var peak = 0.0;
        for (var i = i0; i < i1; i++) {
          peak = max(peak, data[i]);
        }
        final ms = px / w * durationMs;
        final inside = ms >= startMs && ms <= endMs;
        final h = max(1.0, peak * waveH * 0.42);
        canvas.drawRect(
          Rect.fromCenter(
              center: Offset(px + step / 2, mid), width: step * 0.7, height: h * 2),
          Paint()..color = inside ? accent.withValues(alpha: 0.75) : base,
        );
      }
    }
    // 終わりの線
    final ex = x(endMs);
    canvas.drawLine(Offset(ex, 0), Offset(ex, waveH),
        Paint()
          ..color = accent
          ..strokeWidth = 2);
    // 自動で探す範囲（下の帯）
    final bandTop = size.height - _bandH;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(x(min(searchStartMs, durationMs)), bandTop,
            x(min(searchEndMs, durationMs)), size.height),
        const Radius.circular(2),
      ),
      Paint()..color = accent.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(covariant _VersePainter old) =>
      old.endMs != endMs ||
      old.startMs != startMs ||
      old.searchStartMs != searchStartMs ||
      old.searchEndMs != searchEndMs ||
      old.waveform != waveform ||
      old.base != base;
}
