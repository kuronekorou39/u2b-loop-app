import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/dj_level.dart';
import '../../core/audio/transition_effect.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';
import '../../widgets/glass_scaffold.dart';
import '../../widgets/player/dj_mix_sheet.dart';
import '../../widgets/player/first_verse_sheet.dart';
import '../../widgets/player/more_tile.dart';
import '../../widgets/player/sfx_offset_stepper.dart';

/// 設定「DJ ミックス」。縦でも横でもスクロールせずに全部収める。
///
/// よく触るもの（クロスフェードの長さ・レベル・おまかせと 1番）は大きく、残りは
/// 群（つなぎ / 演出・効果音 / 表示）ごとに丸いアイコンのボタンを 1 列に並べる。
/// ボタンはアイコン + 短い名前 + 今の値（オンオフは「オン」「オフ」とアイコンの灰色）。
/// 候補から選ぶものはボタンの上にメニューを出す。
/// クロスフェードがオフの間だけ薄くして触れない（並びは動かさない）。おまかせ中に手動の項目を
/// 変えると、おまかせを切ってカスタムに移る（制限はしない）。
/// 縦は上から順に、横は左に大きいもの・右にアイコンの群
class DjMixSettingsScreen extends ConsumerWidget {
  const DjMixSettingsScreen({super.key});

  /// 長いもの（32 拍から）は小節で数える（8 小節・16 小節・32 小節）
  static String crossfadeLabel(int beats) => beats == 0
      ? 'オフ'
      : beats >= 32
      ? '${beats ~/ 4}小節'
      : '$beats拍';

  /// 段階の表示（どれとも一致しなければ「カスタム」）
  static String levelLabel(DjLevel? level) => level?.label ?? 'カスタム';

  /// 横に 2 列で並べる幅（これより狭いか縦長なら上下に積む）
  static const wideMinWidth = 600.0;

  /// 横のときの左の列（大きいもの）の幅
  static const _leftMin = 260.0;
  static const _leftMax = 360.0;

  /// 中身の幅の上限（広い画面で間延びしないように）
  static const _maxContentWidth = 960.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    return GlassScaffold(
      title: Text('DJ ミックス', style: textTheme.titleMedium),
      bodyBuilder: (context) {
        final padding = MediaQuery.paddingOf(context);
        final viewPadding = MediaQuery.viewPaddingOf(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl + viewPadding.left,
            padding.top + AppSpacing.md,
            AppSpacing.xl + viewPadding.right,
            padding.bottom + AppSpacing.xl,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: LayoutBuilder(
                builder: (context, c) {
                  final wide =
                      c.maxWidth >= wideMinWidth && c.maxWidth > c.maxHeight;
                  if (!wide) {
                    return const Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _MainControls(),
                        SizedBox(height: AppSpacing.xxl),
                        _IconGroups(),
                      ],
                    );
                  }
                  final left = (c.maxWidth * 0.38)
                      .clamp(_leftMin, _leftMax)
                      .toDouble();
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: left, child: const _MainControls()),
                      const SizedBox(width: AppSpacing.xxl),
                      const Expanded(child: _IconGroups()),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 大きく出すもの: クロスフェードの長さ（つまみ）・レベル・おまかせ
class _MainControls extends ConsumerWidget {
  const _MainControls();

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
                label: DjMixSettingsScreen.crossfadeLabel(options[index]),
                onChanged: (v) => ref.read(crossfadeProvider.notifier).value =
                    options[v.round()],
              ),
            ),
            // 幅を固定してつまみの長さが値で変わらないように
            SizedBox(
              width: 64,
              child: Text(
                DjMixSettingsScreen.crossfadeLabel(crossfade),
                textAlign: TextAlign.end,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
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
        const SizedBox(height: AppSpacing.lg),
        // 2 曲の解析結果（テンポ・ビートの安定・ドロップ・音量の流れ）からレシピを選ぶ
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: _WideToggle(
                  icon: Icons.auto_mode,
                  label: 'おまかせ',
                  value: auto,
                  enabled: on,
                  onChanged: (v) =>
                      ref.read(autoMixProvider.notifier).value = v,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 1番モードで「1 番の終わり」を自動で探す範囲。曲ごとの手直しは再生画面の「1番」の長押し
              Expanded(
                flex: 2,
                child: _WideButton(
                  icon: Icons.looks_one_outlined,
                  label: '1番',
                  value: VerseRangeNotifier.label(
                    ref.watch(verseSearchRangeProvider),
                  ),
                  tooltip: '1番を探す範囲',
                  onTap: () => VerseRangeDialog.show(context),
                ),
              ),
            ],
          ),
        ),
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
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    // オフは名前を灰色に
                    color: enabled && value ? onSurface : muted,
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

/// 横長の大きなボタン（1番を探す範囲）。おまかせの横に同じ高さで
class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.icon,
    required this.label,
    required this.value,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppRadius.xl);
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
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: AppIconSizes.xl, color: AppTheme.accentGreen),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppTheme.muted(context),
                        ),
                      ),
                    ],
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

/// 上下のスイッチと丸いボタンを群ごとに並べる。幅に余裕があれば群を横に並べる
class _IconGroups extends ConsumerWidget {
  const _IconGroups();

  /// ボタン 1 つの幅の上限。これに満たない幅では 1 行に 6 つ（いちばん多い群）
  static const maxCellWidth = 64.0;

  /// 詰めるときの下限（5 文字の「タイミング」が入る幅）
  static const minCellWidth = 56.0;

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

    _Cell picker<T>(
      IconData icon,
      String label,
      String tooltip, {
      required List<T> values,
      required T selected,
      required String Function(T) labelOf,
      required void Function(T) onPicked,
      required bool enabled,
    }) => _Cell(
      icon: icon,
      label: label,
      tooltip: tooltip,
      value: labelOf(selected),
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
          // 低音の衝突（混ざる部分がぼやける主因）を避ける
          toggle(
            Icons.graphic_eq,
            '低音入替',
            'ベーススワップ',
            bassSwapProvider,
            enabled: on,
            set: (v) {
              leaveAutoMix(ref);
              ref.read(bassSwapProvider.notifier).value = v;
            },
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
        // 後ろの 2 群（3 + 4）が 1 行に入るなら少し詰めても入れる（横向きの電話で 2 行に収める）。
        // 入らなければ、いちばん多い群（6）が 1 行に入る幅
        final most = groups.map((g) => g.$2.length).reduce(max);
        final pairCount = groups[1].$2.length + groups[2].$2.length;
        final pair = (c.maxWidth - groupGap) / pairCount;
        final cell = min(
          maxCellWidth,
          pair >= minCellWidth ? pair : c.maxWidth / most,
        ).floorToDouble();
        return Wrap(
          spacing: groupGap,
          runSpacing: AppSpacing.lg,
          children: [
            for (final (title, cells) in groups)
              Column(
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
              ),
          ],
        );
      },
    );
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
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
                if (value != null)
                  Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: muted.withValues(alpha: 0.9),
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
