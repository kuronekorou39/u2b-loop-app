import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_state.dart';
import '../../providers/player_provider.dart';
import '../glass_panel.dart';
import 'player_controls.dart';
import 'player_glass_bar.dart';

/// 単体再生画面の下部コントローラー（[PlayerGlassBar] の中身）。
///
/// シーク領域（波形 + ミニマップ + ズーム）/ 先頭(A)へ・−N 秒・再生(大)・+N 秒・ループ ON/OFF /
/// ピル（区間・編集・速度・その他）。
/// 区間パネルを開いている間は [compact]。AB 編集中は [editBlock] をシーク領域の下に出し、
/// ピルは「保存して終了」になる。
class SinglePlayerBar extends ConsumerWidget {
  const SinglePlayerBar({
    super.key,
    required this.seekbar,
    required this.compact,
    required this.loop,
    required this.onToggleLoop,
    required this.editing,
    required this.canEdit,
    required this.onToggleRegions,
    required this.onEdit,
    required this.onFinishEdit,
    required this.onMore,
    this.editBlock,
  });

  final Widget seekbar;
  final bool compact;

  /// いまのループ状態（ON/OFF と A 点を使う）
  final LoopState loop;
  final VoidCallback? onToggleLoop;

  /// AB 編集中
  final bool editing;

  /// 区間を選んでいて「編集」に入れる
  final bool canEdit;
  final VoidCallback onToggleRegions;
  final VoidCallback onEdit;
  final VoidCallback onFinishEdit;
  final VoidCallback onMore;

  /// 編集中にシーク領域の下へ出すブロック（A/B の微調整）
  final Widget? editBlock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final hasSource = ref.watch(videoSourceProvider) != null;
    final seekStep = ref.watch(seekStepProvider);
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    // プレイヤーは操作のときだけ取る（build で触らない: テストで差し替えやすくする）
    void seekBy(int seconds) {
      final player = ref.read(playerProvider);
      final target = player.state.position + Duration(seconds: seconds);
      player.seek(target < Duration.zero ? Duration.zero : target);
    }

    return PlayerGlassBar(
      seekbar: seekbar,
      compact: compact,
      extra: editing ? editBlock : null,
      transport: [
        // 先頭へ（ループ中は A へ）
        TransportIconButton(
          icon: Icons.first_page_rounded,
          size: 30,
          tooltip: loop.enabled && loop.hasA ? 'A へ' : '先頭へ',
          onPressed: hasSource
              ? () => ref.read(playerProvider).seek(
                  loop.enabled && loop.hasA ? loop.pointA! : Duration.zero)
              : null,
        ),
        TransportIconButton(
          icon: PlayerControls.rewindIcon(seekStep),
          size: 30,
          tooltip: '$seekStep秒戻す（長押しで秒数）',
          onPressed: hasSource ? () => seekBy(-seekStep) : null,
          onLongPress: (pos) => PlayerControls.showStepMenu(context, pos, ref),
        ),
        BigPlayButton(
          playing: playing,
          enabled: hasSource,
          size: compact
              ? PlayerGlassBar.playSizeCompact
              : PlayerGlassBar.playSize,
          onTap: () => ref.read(playerProvider).playOrPause(),
        ),
        TransportIconButton(
          icon: PlayerControls.forwardIcon(seekStep),
          size: 30,
          tooltip: '$seekStep秒進める（長押しで秒数）',
          onPressed: hasSource ? () => seekBy(seekStep) : null,
          onLongPress: (pos) => PlayerControls.showStepMenu(context, pos, ref),
        ),
        ToggleIconButton(
          icon: Icons.repeat,
          on: loop.enabled,
          onPressed: hasSource ? onToggleLoop : null,
          tooltip: loop.enabled ? 'ループ ON' : 'ループ OFF',
        ),
      ],
      pills: editing
          ? [
              GlassPill(
                onTap: onFinishEdit,
                active: true,
                tooltip: 'AB 区間を保存して編集を終える',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check, size: AppIconSizes.sm,
                        color: AppTheme.accentGreen),
                    const SizedBox(width: AppSpacing.sm),
                    Text('保存して終了',
                        style: theme.textTheme.labelMedium!
                            .copyWith(color: AppTheme.accentGreen)),
                  ],
                ),
              ),
              const Spacer(),
              GlassPill(
                onTap: onMore,
                tooltip: 'その他',
                padding: const EdgeInsets.all(9),
                child: const Icon(Icons.more_horiz, size: AppIconSizes.md),
              ),
            ]
          : [
              GlassPill(
                onTap: onToggleRegions,
                tooltip: 'AB 区間の一覧を開く',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_list_bulleted, size: AppIconSizes.sm),
                    const SizedBox(width: AppSpacing.sm),
                    Text('区間', style: theme.textTheme.labelMedium),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(Icons.keyboard_arrow_up,
                        size: AppIconSizes.sm, color: dim),
                  ],
                ),
              ),
              const Spacer(),
              if (canEdit) ...[
                GlassPill(
                  onTap: onEdit,
                  tooltip: 'AB 区間を編集',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_outlined, size: AppIconSizes.sm, color: dim),
                      const SizedBox(width: AppSpacing.sm),
                      Text('編集', style: theme.textTheme.labelMedium),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              // 速度: タップでメニュー
              PopupMenuButton<double>(
                initialValue: rate,
                tooltip: '速度',
                enabled: hasSource,
                onSelected: (s) => ref.read(playerProvider).setRate(s),
                itemBuilder: (context) => [
                  for (final s in PlayerControls.speeds)
                    PopupMenuItem(
                      value: s,
                      child: Text(
                        '${s}x',
                        style: TextStyle(
                          fontWeight: s == rate ? FontWeight.bold : null,
                          color: s == rate ? theme.colorScheme.primary : null,
                        ),
                      ),
                    ),
                ],
                child: GlassPill(
                  onTap: null,
                  active: rate != 1.0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg, vertical: 9),
                  child: Text(
                    '${rate}x',
                    style: theme.textTheme.labelMedium!.copyWith(
                      color: rate != 1.0 ? AppTheme.accentGreen : null,
                      fontFeatures: const [FontFeature('tnum')],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              GlassPill(
                onTap: onMore,
                tooltip: 'その他',
                padding: const EdgeInsets.all(9),
                child: const Icon(Icons.more_horiz, size: AppIconSizes.md),
              ),
            ],
    );
  }
}
