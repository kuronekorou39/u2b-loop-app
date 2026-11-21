import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/band_swap.dart';
import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/dj_level.dart';
import '../../core/audio/transition_effect.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';
import 'first_verse_sheet.dart';
import 'more_tile.dart';
import 'sfx_offset_stepper.dart';

/// DJ ミックスの設定の中身。設定の「DJ ミックス」のページと、再生画面の「DJ ミックス」の
/// ポップアップ（[DjMixSheet]）の両方がこれを使う（見た目も並びも同じ。項目を足すのはここだけ）。
///
/// よく触るもの（クロスフェードの長さ・レベル・おまかせと 1番）は大きく、残りは
/// 群（つなぎ / 演出・効果音 / 表示）ごとに並べる。オンオフは上下のスイッチ（「オン」「オフ」の
/// 文字は出さず、オフは名前を灰色に）、候補から選ぶものは丸いボタン（下に今の値、押すと
/// ボタンの下にメニュー）。
/// クロスフェードがオフの間だけ薄くして触れない（並びは動かさない。表示の群は別）。
/// おまかせ中に手動の項目を変えると、おまかせを切ってカスタムに移る（制限はしない）。
/// 縦は上から順に、横（幅 [wideMinWidth] 以上で横長）は左に大きいもの・右に群。
/// 行の間は余裕があれば [gapMax] まで広げ、狭いときは [gapMin] まで詰める。
/// スクロールはしない。[shrinkWrap] はポップアップ用で、高さを中身に合わせる
/// （ページは画面の高さいっぱいに使う）
class DjMixControls extends StatelessWidget {
  const DjMixControls({super.key, this.shrinkWrap = false});

  final bool shrinkWrap;

  /// 行と行の間（群の行どうし・横の左の列）
  static const gapMin = AppSpacing.lg;
  static const gapMax = 36.0;

  /// 横の左の列の「おまかせ」「1番」の高さ（1 行ずつ同じ高さに）
  static const wideRowHeight = 64.0;

  /// 横で「おまかせ」「1番」を 1 行ずつにする中身の高さの下限。これより低い画面
  /// （小さい横向きの電話）は縦と同じく横に並べる（1 行ずつだと 1番が下で切れた）
  static const stackRowsMinHeight = 264.0;

  /// 横に 2 列で並べる幅（これより狭いか縦長なら上下に積む）
  static const wideMinWidth = 600.0;

  /// 横のときの左の列（大きいもの）の幅
  static const _leftMin = 260.0;
  static const _leftMax = 360.0;

  /// 長いもの（32 拍から）は小節で数える（8 小節・16 小節・32 小節）
  static String crossfadeLabel(int beats) => beats == 0
      ? 'オフ'
      : beats >= 32
      ? '${beats ~/ 4}小節'
      : '$beats拍';

  /// 段階の表示（どれとも一致しなければ「カスタム」）
  static String levelLabel(DjLevel? level) => level?.label ?? 'カスタム';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= wideMinWidth && c.maxWidth > c.maxHeight;
        if (!wide) {
          // 群の上と群の行の間は、下に余っている分から広げる
          return Column(
            mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _MainControls(wide: false),
              if (shrinkWrap)
                const Flexible(child: _IconGroups(leadingGap: true))
              else
                const Expanded(child: _IconGroups(leadingGap: true)),
            ],
          );
        }
        final left = (c.maxWidth * 0.38).clamp(_leftMin, _leftMax).toDouble();
        final stack = c.maxHeight >= stackRowsMinHeight;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: left, child: _MainControls(wide: stack)),
            const SizedBox(width: AppSpacing.xxl),
            const Expanded(child: _IconGroups(leadingGap: false)),
          ],
        );
      },
    );
  }
}

/// 余裕があれば [DjMixControls.gapMax] まで広がる行の間（狭い画面では
/// [DjMixControls.gapMin] まで詰まる）。高さに上限のある Column の中だけで使う
List<Widget> _flexGap() => const [
  SizedBox(height: DjMixControls.gapMin),
  Flexible(
    child: SizedBox(
      height: DjMixControls.gapMax - DjMixControls.gapMin,
    ),
  ),
];

/// 大きく出すもの: クロスフェードの長さ（つまみ）・レベル・おまかせと 1番。
/// 横（[wide]）は左の列で、おまかせと 1番を 1 行ずつ、行の間は右の群の行の間と同じだけ広げる。
/// 縦（と低い横画面）はおまかせと 1番を横に並べ、間は詰める（広げるのは下の群の上下）
class _MainControls extends ConsumerWidget {
  const _MainControls({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    final auto = ref.watch(autoMixProvider);
    const options = CrossfadeNotifier.options;
    // 候補に無い値（古い版で保存したもの）はいちばん近い段に
    var index = options.indexOf(crossfade);
    if (index < 0) {
      var best = 0;
      for (var i = 1; i < options.length; i++) {
        if ((options[i] - crossfade).abs() <
            (options[best] - crossfade).abs()) {
          best = i;
        }
      }
      index = best;
    }
    // 2 曲の解析結果（テンポ・ビートの安定・ドロップ・音量の流れ）からレシピを選ぶ
    final autoToggle = _WideToggle(
      icon: Icons.auto_mode,
      label: 'おまかせ',
      value: auto,
      enabled: on,
      onChanged: (v) => ref.read(autoMixProvider.notifier).value = v,
    );
    // 1番モードで「1 番の終わり」を自動で探す範囲。曲ごとの手直しは再生画面の「1番」の長押し
    final verseButton = _WideButton(
      icon: Icons.looks_one_outlined,
      label: '1番',
      value: VerseRangeNotifier.label(ref.watch(verseSearchRangeProvider)),
      tooltip: '1番を探す範囲',
      inline: wide,
      onTap: () => VerseRangeDialog.show(context),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // プレイリストで次曲がプリロード済みのとき、B点/終端の手前から重ねて鳴らす長さ
        Row(
          children: [
            Tooltip(
              message: 'クロスフェード',
              child: Icon(
                Icons.multitrack_audio,
                size: AppIconSizes.lg,
                color: on ? AppTheme.accentGreen : AppTheme.muted(context),
              ),
            ),
            Expanded(
              child: Slider(
                value: index.toDouble(),
                min: 0,
                max: (options.length - 1).toDouble(),
                divisions: options.length - 1,
                label: DjMixControls.crossfadeLabel(options[index]),
                onChanged: (v) => ref.read(crossfadeProvider.notifier).value =
                    options[v.round()],
              ),
            ),
            // 幅を固定してつまみの長さが値で変わらないように
            SizedBox(
              width: 64,
              child: Text(
                DjMixControls.crossfadeLabel(crossfade),
                textAlign: TextAlign.end,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (wide) ..._flexGap() else const SizedBox(height: AppSpacing.md),
        // 控えめ・普通・ガチ。選ぶと下の個々の設定がまとめて変わる（変えるとどれも選ばれない）
        const Row(
          children: [
            Tooltip(
              message: 'つなぎ方のレベル',
              child: Icon(Icons.tune, size: AppIconSizes.lg),
            ),
            SizedBox(width: AppSpacing.lg),
            Expanded(child: DjLevelChips()),
          ],
        ),
        if (wide) ...[
          ..._flexGap(),
          SizedBox(height: DjMixControls.wideRowHeight, child: autoToggle),
          ..._flexGap(),
          SizedBox(height: DjMixControls.wideRowHeight, child: verseButton),
        ] else ...[
          const SizedBox(height: AppSpacing.lg),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: autoToggle),
                const SizedBox(width: AppSpacing.sm),
                Expanded(flex: 2, child: verseButton),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 横長の大きなオンオフ（おまかせ）。右端にスイッチ。面は塗り分けず、オフはアイコンと名前が灰色
class _WideToggle extends StatelessWidget {
  const _WideToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final muted = AppTheme.muted(context);
    final radius = BorderRadius.circular(AppRadius.xl);
    final alpha = enabled ? 1.0 : 0.4;
    return Material(
      color: onSurface.withValues(alpha: enabled ? 0.08 : 0.04),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.lg,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: AppIconSizes.xl,
                color: (value ? AppTheme.accentGreen : muted).withValues(
                  alpha: alpha,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              // 狭い列（低い横画面で 1番と横に並べたとき）は折り返さずに少し縮める
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      // オフは名前を灰色に
                      color: enabled && value ? onSurface : muted,
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: Switch(
                  value: value,
                  onChanged: enabled ? onChanged : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 横長の大きなボタン（1番を探す範囲）。縦はおまかせの横に同じ高さで（名前の下に値）、
/// 横（[inline]）はおまかせの下の 1 行で（名前の右端に値。おまかせのスイッチと同じ位置）
class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.icon,
    required this.label,
    required this.value,
    required this.tooltip,
    required this.onTap,
    this.inline = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String tooltip;
  final VoidCallback onTap;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppRadius.xl);
    final labelText = Text(
      label,
      maxLines: 1,
      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
    );
    final valueText = Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (inline ? theme.textTheme.bodyMedium : theme.textTheme.labelSmall)
          ?.copyWith(color: AppTheme.muted(context)),
    );
    return Tooltip(
      message: tooltip,
      child: Material(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: inline
                // おまかせ（_WideToggle）と同じ余白でアイコンと名前の位置をそろえる
                ? const EdgeInsets.symmetric(horizontal: AppSpacing.xl)
                : const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
            child: Row(
              children: [
                Icon(icon, size: AppIconSizes.xl, color: AppTheme.accentGreen),
                SizedBox(width: inline ? AppSpacing.lg : AppSpacing.md),
                if (inline) ...[
                  labelText,
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Align(alignment: Alignment.centerRight, child: valueText),
                  ),
                ] else
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [labelText, valueText],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 上下のスイッチと丸いボタンを群ごとに並べる。幅に余裕があれば群を横に並べ、
/// 行の間は余裕に合わせて広げる（[leadingGap] なら 1 行目の上も。縦の大きいものとの間）
class _IconGroups extends ConsumerWidget {
  const _IconGroups({required this.leadingGap});

  final bool leadingGap;

  /// ボタン 1 つの幅の上限。これに満たない幅では 1 行に 6 つ（いちばん多い群）
  static const maxCellWidth = 64.0;

  /// 詰めるときの下限。名前は入らなければ少し縮めて出すので、丸いボタン（44）の左右が
  /// 詰まりすぎない幅まで詰める（小さい縦の電話でも群を 2 行に収める。56 では 3 行になって下が切れた）
  static const minCellWidth = 50.0;

  /// 群と群の間
  static const groupGap = AppSpacing.xl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    final curve = ref.watch(crossfadeCurveProvider);
    final effect = ref.watch(transitionEffectProvider);

    _Cell toggle(
      IconData icon,
      String label,
      String tooltip,
      ProviderListenable<bool> provider, {
      required bool enabled,
      required void Function(bool) set,
    }) {
      final value = ref.watch(provider);
      return _Cell(
        icon: icon,
        label: label,
        tooltip: tooltip,
        switchValue: value,
        enabled: enabled,
        onTap: (_) => set(!value),
      );
    }

    // [shortOf] はボタンの下に出す短い名前（無ければメニューと同じ名前）
    _Cell picker<T>(
      IconData icon,
      String label,
      String tooltip, {
      required List<T> values,
      required T selected,
      required String Function(T) labelOf,
      String Function(T)? shortOf,
      required void Function(T) onPicked,
      required bool enabled,
    }) => _Cell(
      icon: icon,
      label: label,
      tooltip: tooltip,
      value: (shortOf ?? labelOf)(selected),
      enabled: enabled,
      onTap: (ctx) async {
        final picked = await showAnchoredPicker<T>(
          ctx,
          values: values,
          selected: selected,
          labelOf: labelOf,
        );
        if (picked != null) onPicked(picked);
      },
    );

    final groups = <(String, List<_Cell>)>[
      (
        'つなぎ',
        [
          // 対称な等パワーだけだと中間がぼやけるので、DJ らしい非対称やカットも選べる
          picker<CrossfadeCurve>(
            Icons.show_chart,
            'つなぎ方',
            'つなぎ方',
            values: CrossfadeCurve.values,
            selected: curve,
            labelOf: (c) => c.label,
            onPicked: (v) {
              leaveAutoMix(ref);
              ref.read(crossfadeCurveProvider.notifier).value = v;
            },
            enabled: on,
          ),
          // 波形から求めたドロップが切り替わりに来るよう次曲の開始位置をずらす
          toggle(
            Icons.trending_up,
            'ドロップ',
            'ドロップに合わせる',
            mixPointAlignProvider,
            enabled: on,
            set: (v) => ref.read(mixPointAlignProvider.notifier).value = v,
          ),
          // 次曲の静かなイントロを飛ばす・前曲の静かで長いアウトロを待たない
          toggle(
            Icons.login,
            '出入り口',
            '出入り口を選ぶ',
            smartEntryProvider,
            enabled: on,
            set: (v) => ref.read(smartEntryProvider.notifier).value = v,
          ),
          // 次曲の速度を ±8% まで寄せ、交差後に元へ戻す
          toggle(
            Icons.speed,
            'テンポ',
            'テンポ合わせ',
            tempoMatchProvider,
            enabled: on,
            set: (v) {
              leaveAutoMix(ref);
              ref.read(tempoMatchProvider.notifier).value = v;
            },
          ),
          // 重ね始めの拍の頭を揃え、交差中は速度を微調整して合わせ続ける
          toggle(
            Icons.align_horizontal_center,
            '拍合わせ',
            '拍合わせ',
            beatMatchProvider,
            enabled: on,
            set: (v) {
              leaveAutoMix(ref);
              ref.read(beatMatchProvider.notifier).value = v;
            },
          ),
          // 低音の衝突（混ざる部分がぼやける主因）を避ける。3 帯域は高音 → 中音 → 低音の順
          picker<BandSwap>(
            Icons.graphic_eq,
            '入れ替え',
            '帯域の入れ替え',
            values: BandSwap.values,
            selected: ref.watch(bandSwapProvider),
            labelOf: (b) => b.label,
            onPicked: (v) {
              leaveAutoMix(ref);
              ref.read(bandSwapProvider.notifier).value = v;
            },
            enabled: on,
          ),
        ],
      ),
      (
        '演出・効果音',
        [
          picker<TransitionEffect>(
            Icons.auto_awesome,
            '演出',
            '切り替えの演出',
            values: TransitionEffect.values,
            selected: effect,
            labelOf: (e) => e.label,
            shortOf: (e) => e.short,
            onPicked: (v) {
              leaveAutoMix(ref);
              ref.read(transitionEffectProvider.notifier).value = v;
            },
            enabled: on,
          ),
          picker<int>(
            Icons.campaign,
            '効果音',
            '効果音の音量',
            values: SfxLevelNotifier.options,
            selected: ref.watch(sfxLevelProvider),
            labelOf: SfxLevelNotifier.label,
            onPicked: (v) => ref.read(sfxLevelProvider.notifier).value = v,
            enabled: on,
          ),
          // 効果音が拍より遅れて / 早く聞こえるときに 10ms 刻みで詰める（ボタンの下に −/+）
          _Cell(
            icon: Icons.timer_outlined,
            label: 'タイミング',
            tooltip: '効果音のタイミング',
            value: SfxOffsetNotifier.label(ref.watch(sfxOffsetMsProvider)),
            enabled: on,
            onTap: (ctx) => showMenu<void>(
              context: ctx,
              position: anchoredMenuPosition(ctx),
              items: [const _StepperEntry()],
            ),
          ),
        ],
      ),
      (
        '表示',
        [
          // 重ね表示に拍の線（1 拍目は濃く）と拍のずれ
          toggle(
            Icons.view_week_outlined,
            '拍の線',
            '拍の線を表示',
            showBeatLinesProvider,
            enabled: true,
            set: (v) => ref.read(showBeatLinesProvider.notifier).value = v,
          ),
          // プレイリストの波形（拡大できない）にも小節頭・4 小節ごとの線と変わり目の印
          toggle(
            Icons.view_column_outlined,
            '一覧の線',
            'プレイリストの波形に拍の線',
            playlistBeatLinesProvider,
            enabled: true,
            set: (v) => ref.read(playlistBeatLinesProvider.notifier).value = v,
          ),
          // 音量曲線（つなぎ方の 2 本の線）。デッキの板からも切り替えられる
          toggle(
            Icons.ssid_chart,
            '音量の線',
            '音量の線を表示',
            showMixCurvesProvider,
            enabled: true,
            set: (v) => ref.read(showMixCurvesProvider.notifier).value = v,
          ),
        ],
      ),
    ];

    final textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final cell = cellWidthFor(width, [for (final g in groups) g.$2.length]);
        Widget group(String title, List<_Cell> cells) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: textTheme.labelMedium?.copyWith(
                color: AppTheme.muted(context),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final x in cells) SizedBox(width: cell, child: x),
              ],
            ),
          ],
        );
        final rows = rowsFor(width, cell, [for (final g in groups) g.$2.length]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0 || leadingGap) ..._flexGap(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (k, i) in rows[r].indexed) ...[
                    if (k > 0) const SizedBox(width: groupGap),
                    group(groups[i].$1, groups[i].$2),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// ボタン 1 つの幅。1 群目（つなぎ）の後ろの群がまとめて 1 行に入るなら少し詰めても入れる
  /// （横向きの電話で 2 行に収める）。入らなければ、いちばん多い群が 1 行に入る幅
  static double cellWidthFor(double width, List<int> counts) {
    final most = counts.reduce(max);
    final rest = counts.skip(1).fold(0, (a, b) => a + b);
    final together = (width - groupGap * (counts.length - 2)) / rest;
    return min(
      maxCellWidth,
      together >= minCellWidth ? together : width / most,
    ).floorToDouble();
  }

  /// 群を行に分ける（群の番号の並び）。1 群目は 1 行目、続く群は入るだけ同じ行に
  static List<List<int>> rowsFor(double width, double cell, List<int> counts) {
    final rows = <List<int>>[];
    var used = 0.0;
    for (var i = 0; i < counts.length; i++) {
      final w = counts[i] * cell;
      if (rows.isNotEmpty && i > 1 && used + groupGap + w <= width) {
        rows.last.add(i);
        used += groupGap + w;
      } else {
        rows.add([i]);
        used = w;
      }
    }
    return rows;
  }
}

/// 群の中の 1 つ。オンオフは上下のスイッチ（つまみに アイコン、上がオン）+ 短い名前、
/// それ以外は丸いボタン（アイコン + 短い名前 + 今の値）。高さはどちらも同じ。
/// オフは名前を灰色にするだけ（「オン」「オフ」の文字は出さない）。
/// クロスフェードがオフの間は全体を薄く。長押しで正式な名前
class _Cell extends StatelessWidget {
  const _Cell({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    this.value,
    this.switchValue,
  }) : assert((value == null) != (switchValue == null));

  final IconData icon;
  final String label;
  final String tooltip;

  /// 今の値（丸いボタン）
  final String? value;

  /// オンオフ（上下のスイッチ）
  final bool? switchValue;
  final bool enabled;

  /// 押したボタンの context を渡す（メニューをその下に出す）
  final void Function(BuildContext) onTap;

  static const circle = 44.0;

  /// 上下のスイッチの大きさ（丸いボタン + 値の行と同じ高さ）
  static const switchWidth = 30.0;
  static const switchHeight = 60.0;
  static const knob = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final muted = AppTheme.muted(context);
    final sw = switchValue;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w600,
      color: sw == false ? muted : onSurface,
    );
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: InkWell(
          onTap: enabled ? () => onTap(context) : null,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sw != null)
                  _VerticalSwitch(icon: icon, value: sw)
                else
                  Container(
                    width: circle,
                    height: circle,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: onSurface.withValues(alpha: 0.08),
                    ),
                    child: Icon(
                      icon,
                      size: AppIconSizes.lg,
                      color: AppTheme.accentGreen,
                    ),
                  ),
                const SizedBox(height: AppSpacing.xs),
                // 狭い画面（ボタンの幅 56 未満）では「…」で切らずに少し縮めて全部出す
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, maxLines: 1, style: labelStyle),
                ),
                if (value != null)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value!,
                      maxLines: 1,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: muted.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 上下のスイッチ（見た目だけ。押すのは [_Cell] の全体）。オンはつまみが上で緑
class _VerticalSwitch extends StatelessWidget {
  const _VerticalSwitch({required this.icon, required this.value});

  final IconData icon;
  final bool value;

  static const _duration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    const pad = (_Cell.switchWidth - _Cell.knob) / 2;
    return AnimatedContainer(
      duration: _duration,
      width: _Cell.switchWidth,
      height: _Cell.switchHeight,
      padding: const EdgeInsets.all(pad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_Cell.switchWidth / 2),
        color: value
            ? AppTheme.accentGreen.withValues(alpha: 0.35)
            : onSurface.withValues(alpha: 0.12),
      ),
      child: AnimatedAlign(
        duration: _duration,
        curve: Curves.easeOut,
        alignment: value ? Alignment.topCenter : Alignment.bottomCenter,
        child: AnimatedContainer(
          duration: _duration,
          width: _Cell.knob,
          height: _Cell.knob,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value
                ? AppTheme.accentGreen
                : onSurface.withValues(alpha: 0.45),
          ),
          child: Icon(
            icon,
            size: AppIconSizes.xs,
            color: theme.colorScheme.surface,
          ),
        ),
      ),
    );
  }
}

/// 効果音のタイミングのメニューの中身（−/+ を押してもメニューは閉じない）
class _StepperEntry extends PopupMenuEntry<void> {
  const _StepperEntry();

  @override
  double get height => kMinInteractiveDimension;

  @override
  bool represents(void value) => false;

  @override
  State<_StepperEntry> createState() => _StepperEntryState();
}

class _StepperEntryState extends State<_StepperEntry> {
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
    child: SfxOffsetStepper(),
  );
}

/// つなぎ方のレベル（控えめ・普通・ガチ・カスタム）の 4 つのボタン。[DjMixControls] の中。
///
/// 下の個々の設定をまとめて変えるプリセットなので、どれも同じように押せる見た目にする
/// （選ばれていないものを灰色にしない）。今の設定と一致するものだけ緑の枠と文字。
/// どれとも一致しなければカスタム。カスタムを押すとおまかせを切り、個々の設定は今のまま
/// （個々の設定は制限せず、おまかせ中に手で変えてもカスタムに移る）
class DjLevelChips extends ConsumerWidget {
  const DjLevelChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final level = ref.watch(djLevelProvider);
    final radius = BorderRadius.circular(AppRadius.lg);
    return Row(
      children: [
        // null = カスタム
        for (final (i, l) in <DjLevel?>[...DjLevel.values, null].indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Material(
              color: onSurface.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: l == level
                    ? const BorderSide(color: AppTheme.accentGreen, width: 1.5)
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () =>
                    l == null ? applyDjCustom(ref) : applyDjLevel(ref, l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(
                    DjMixControls.levelLabel(l),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: l == level ? AppTheme.accentGreen : onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
