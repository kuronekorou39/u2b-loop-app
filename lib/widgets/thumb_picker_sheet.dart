import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/ui/app_sheets.dart';
import '../models/loop_item.dart';
import 'item_thumbnail.dart';

/// 曲の中からサムネにする 1 曲を選ぶシート（プレイリスト・タグの一覧のサムネ）。
/// [currentId] は今のサムネの曲（チェックを付ける）。[custom] なら手で選んだ状態なので
/// 先頭に「[resetLabel]」を出し、押すと [onPick] に null を渡す
class ThumbPickerSheet {
  ThumbPickerSheet._();

  static Future<void> show(
    BuildContext context, {
    required List<LoopItem> items,
    required String? currentId,
    required bool custom,
    required String resetLabel,
    required ValueChanged<String?> onPick,
  }) {
    return AppSheets.show<void>(
      context,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
                child: Text('サムネイル選択', style: textTheme.titleMedium),
              ),
              const Divider(height: 1),
              if (custom)
                ListTile(
                  leading: const Icon(Icons.restart_alt),
                  title: Text(resetLabel),
                  onTap: () {
                    onPick(null);
                    Navigator.pop(ctx);
                  },
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  // 最後の行が画面の下端に付かないように
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: AppRadius.borderXs,
                        child: SizedBox(
                          width: 48,
                          height: 36,
                          child: ItemThumbnail(item: item, iconSize: AppIconSizes.sm),
                        ),
                      ),
                      title: Text(item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium),
                      trailing: item.id == currentId
                          ? const Icon(Icons.check,
                              color: AppTheme.accentGreen, size: AppIconSizes.md)
                          : null,
                      onTap: () {
                        onPick(item.id);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
