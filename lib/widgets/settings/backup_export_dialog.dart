import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';

/// バックアップを書き出す前に、ファイルに入るものと入らないものを見せる。
/// 低い画面（横向きの電話）では 2 列に並べ、見出しとボタンを 1 行にする
class BackupExportDialog extends StatelessWidget {
  const BackupExportDialog({super.key});

  /// ファイルに入るもの（BackupService の書き出す項目を変えたら合わせる）
  static const savedLabels = [
    '曲の一覧',
    'プレイリスト',
    'タグ',
    'AB 区間・1番',
    'メモ・再生速度',
    '再生回数',
    'BPM・キーなどの解析結果',
  ];

  /// ファイルに入らないもの
  static const notSavedLabels = [
    '動画・音声・字幕',
    'サムネイル画像',
    '波形',
    'アプリの設定',
  ];

  /// 書き出すなら true
  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => const BackupExportDialog(),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    const saved =
        _ContentList(title: '保存する', labels: savedLabels, included: true);
    const notSaved =
        _ContentList(title: '保存しない', labels: notSavedLabels, included: false);
    return AppFormDialog(
      title: 'バックアップの中身',
      content: AppFormDialog.compactIn(context)
          ? const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: saved),
                SizedBox(width: AppSpacing.xxl),
                Expanded(child: notSaved),
              ],
            )
          : const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                saved,
                SizedBox(height: AppSpacing.xl),
                notSaved,
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('書き出す'),
        ),
      ],
    );
  }
}

/// 見出しと、印の付いた項目の縦の並び
class _ContentList extends StatelessWidget {
  const _ContentList({
    required this.title,
    required this.labels,
    required this.included,
  });

  final String title;
  final List<String> labels;

  /// ファイルに入るもの（緑の ✓）か、入らないもの（灰色の ✕）か
  final bool included;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppTheme.muted(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelMedium!.copyWith(
            fontWeight: FontWeight.bold,
            color: included ? theme.colorScheme.primary : muted,
          ),
        ),
        for (final label in labels)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Row(
              children: [
                Icon(
                  included ? Icons.check : Icons.close,
                  size: AppIconSizes.s,
                  color: included ? AppTheme.accentGreen : muted,
                ),
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium!
                        .copyWith(color: included ? null : muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
