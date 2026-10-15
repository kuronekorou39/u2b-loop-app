import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';
import '../item_thumbnail.dart';
import 'video_player_widget.dart';

/// 曲を開いている間に動画枠へ出すもの: サムネイルを暗くして、下に進捗バーと一行の文言。
/// 画面そのものは再生画面のまま（曲名・タグ・一覧は触れる）で、ここだけが待ち状態になる。
/// 進捗・文言は ValueListenable で局所的に更新する
class PlayerLoadingStage extends StatelessWidget {
  const PlayerLoadingStage({
    super.key,
    required this.item,
    required this.progress,
    required this.status,
  });

  final LoopItem item;
  final ValueListenable<double> progress;
  final ValueListenable<String> status;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        ItemThumbnail(item: item),
        const ColoredBox(color: Colors.black45),
        Positioned(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: AppSpacing.xl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (context, text, _) => Text(
                  text,
                  style: textTheme.labelMedium!.copyWith(color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, _) => TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: value),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  builder: (context, animated, _) => ClipRRect(
                    borderRadius: AppRadius.borderXs,
                    child: LinearProgressIndicator(
                      value: animated,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      color: AppTheme.accentGreen,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 読み込み失敗時に動画枠へ出すもの。
/// [onSkip] を渡すとプレイリスト用の「次の曲へスキップ」ボタンが出る
class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.onSkip,
    this.stoppedByRepeatedErrors = false,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onSkip;

  /// 連続エラーで自動スキップを打ち切ったかどうか
  final bool stoppedByRepeatedErrors;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: AppIconSizes.xl, color: Colors.orange),
              const SizedBox(height: AppSpacing.md),
              Text('読み込み失敗',
                  style: textTheme.titleMedium!.copyWith(color: Colors.white)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: textTheme.bodySmall!.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (stoppedByRepeatedErrors)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    '連続でエラーが発生したため停止しました',
                    style: textTheme.bodySmall!.copyWith(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: AppIconSizes.sm),
                    label: const Text('再試行'),
                  ),
                  if (onSkip != null)
                    OutlinedButton.icon(
                      onPressed: onSkip,
                      icon: const Icon(Icons.skip_next, size: AppIconSizes.sm),
                      label: const Text('次の曲へスキップ'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ピクチャーインピクチャー表示用の最小構成ビュー。
/// PiPウィンドウは小さいので映像だけを出す。
class PiPVideoView extends StatelessWidget {
  const PiPVideoView({
    super.key,
    required this.hideVideo,
    required this.loading,
  });

  final bool hideVideo;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: hideVideo
          ? const SizedBox.shrink()
          : loading
              ? const Center(
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Center(child: VideoPlayerWidget()),
    );
  }
}
