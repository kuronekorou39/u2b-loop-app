import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';

/// 取り込む曲に付けるタグの決め方
enum _ImportTagChoice { named, pick, none }

/// YouTube のプレイリストを取り込むとき、曲に共通のタグを付けるかを聞く。
/// 選ぶのは 3 つだけ: プレイリスト名のタグ（[newTagName]。無ければ作る）を付ける /
/// 今あるタグから選ぶ（一覧は次のダイアログ。タグが多くても最初の画面に並べない）/ 付けない。
/// 戻り値は付けるタグの ID（付けない・閉じたときは null）
Future<String?> showImportTagDialog(
  BuildContext context, {
  required List<Tag> tags,
  required String newTagName,
  required Future<Tag> Function(String name) createTag,
}) async {
  final sameName = tags.where((t) => t.name == newTagName).firstOrNull;
  while (true) {
    final choice = await showDialog<_ImportTagChoice>(
      context: context,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        Widget row(_ImportTagChoice value, IconData icon, String label,
                {bool opens = false}) =>
            ListTile(
              leading: Icon(icon, color: AppTheme.accentGreen),
              title: Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyLarge),
              trailing: opens ? const Icon(Icons.chevron_right) : null,
              onTap: () => Navigator.pop(ctx, value),
            );
        return AlertDialog(
          title: Text('タグを付ける', style: textTheme.displaySmall),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  row(
                      _ImportTagChoice.named,
                      sameName == null ? Icons.new_label_outlined : Icons.label,
                      sameName == null
                          ? '「$newTagName」を作って付ける'
                          : '「$newTagName」を付ける'),
                  if (tags.isNotEmpty)
                    row(_ImportTagChoice.pick, Icons.label_outline, '今あるタグから選ぶ',
                        opens: true),
                  row(_ImportTagChoice.none, Icons.label_off_outlined, '付けない'),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!context.mounted) return null;
    switch (choice) {
      case null || _ImportTagChoice.none:
        return null;
      case _ImportTagChoice.named:
        return (sameName ?? await createTag(newTagName)).id;
      case _ImportTagChoice.pick:
        final picked = await _pickTag(context, tags);
        if (picked != null || !context.mounted) return picked;
      // 選ばずに閉じたら、最初の 3 択へ戻る
    }
  }
}

/// 今あるタグから 1 つ選ぶ（縦に送れる一覧）
Future<String?> _pickTag(BuildContext context, List<Tag> tags) {
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final textTheme = Theme.of(ctx).textTheme;
      return AlertDialog(
        title: Text('タグを選ぶ', style: textTheme.displaySmall),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: tags.length,
            itemBuilder: (_, i) {
              final tag = tags[i];
              return ListTile(
                dense: true,
                leading: Icon(Icons.label, color: tag.color),
                title: Text(tag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyLarge),
                onTap: () => Navigator.pop(ctx, tag.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('戻る'),
          ),
        ],
      );
    },
  );
}
