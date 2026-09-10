import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/loading_animation_provider.dart';
import '../loading_animations/loading_animation_widget.dart';
import 'video_player_widget.dart';

/// 動画読み込み中の画面。
/// 進捗・ステータス・Tip は ValueListenable で個別に更新するため、
/// 画面全体を再ビルドせずに済む。
class PlayerLoadingView extends ConsumerWidget {
  const PlayerLoadingView({
    super.key,
    required this.title,
    required this.progress,
    required this.status,
    required this.tip,
  });

  final String title;
  final ValueListenable<double> progress;
  final ValueListenable<String> status;
  final ValueListenable<String> tip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        // 背景アニメーション
        Positioned.fill(
          child: LoadingAnimationView(type: ref.read(loadingAnimationProvider)),
        ),
        // 前景: タイトル＋プログレス（ValueListenableBuilderで局所更新）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall!.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xxl),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: value),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeInOut,
                      builder: (context, animated, _) {
                        return ClipRRect(
                          borderRadius: AppRadius.borderXs,
                          child: LinearProgressIndicator(
                            value: animated,
                            minHeight: 6,
                            backgroundColor: colorScheme.surfaceContainerHighest,
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
                ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (context, text, _) {
                    return Text(
                      text,
                      style: textTheme.bodyMedium!.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.xxl),
                // Tip（8秒ごとにフェード切替）
                ValueListenableBuilder<String>(
                  valueListenable: tip,
                  builder: (context, text, _) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 600),
                      child: Text(
                        'Tip: $text',
                        key: ValueKey(text),
                        style: textTheme.bodySmall!.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.35),
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 読み込み失敗時の画面。
/// [onSkip] を渡すとプレイリスト用の「次の曲へスキップ」ボタンが出る。
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: AppIconSizes.xxl, color: Colors.orange),
            const SizedBox(height: AppSpacing.xl),
            Text('読み込み失敗', style: textTheme.displaySmall),
            const SizedBox(height: AppSpacing.md),
            Text(message, style: textTheme.bodySmall, textAlign: TextAlign.center),
            if (stoppedByRepeatedErrors)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  '連続でエラーが発生したため停止しました',
                  style: textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: AppIconSizes.sm),
              label: const Text('再試行'),
            ),
            if (onSkip != null) ...[
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: onSkip,
                icon: const Icon(Icons.skip_next, size: AppIconSizes.sm),
                label: const Text('次の曲へスキップ'),
              ),
            ],
          ],
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
