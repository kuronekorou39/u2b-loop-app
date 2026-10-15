import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/empty_hint.dart';
import 'home_parts.dart';

/// ホームの「タグ」タブ。タグの一覧と、名前・色の変更、削除。
/// 行をタップすると [onTagTap]（曲タブへ移ってそのタグで絞り込む）
class TagManagerTab extends ConsumerWidget {
  const TagManagerTab({super.key, required this.onTagTap});

  final ValueChanged<Tag> onTagTap;

  /// FAB の「タグを作成」
  static Future<void> createTag(BuildContext context, WidgetRef ref) async {
    final name = await AppDialogs.prompt(context,
        title: 'タグを作成',
        hintText: 'タグ名',
        confirmLabel: '作成',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    await ref.read(tagsProvider.notifier).create(name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    final allItems = ref.watch(loopItemsProvider);
    final textTheme = Theme.of(context).textTheme;

    if (tags.isEmpty) {
      return const EmptyHint(
          icon: Icons.label_outline, title: 'タグがありません', subtitle: '＋ ボタンで作成');
    }

    return HomeListSurface(
      child: ListView.builder(
        padding: HomeListSurface.listPadding,
        itemCount: tags.length,
        itemBuilder: (context, i) {
          final tag = tags[i];
          final count =
              allItems.where((item) => item.tagIds.contains(tag.id)).length;
          return ListTile(
            leading: Container(
              width: AppIconSizes.lg,
              height: AppIconSizes.lg,
              decoration: BoxDecoration(
                color: tag.color.withValues(alpha: 0.25),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.label, size: AppIconSizes.xs, color: tag.color),
            ),
            title: Text(tag.name, style: textTheme.bodyLarge),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$count 曲', style: textTheme.bodySmall),
                IconButton(
                  icon: const Icon(Icons.more_vert, size: AppIconSizes.md),
                  tooltip: 'メニュー',
                  onPressed: () => _showMenu(context, ref, tag),
                ),
              ],
            ),
            onTap: () => onTagTap(tag),
            onLongPress: () => _showMenu(context, ref, tag),
          );
        },
      ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref, Tag tag) {
    AppSheets.actions(
      context,
      title: tag.name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _rename(context, ref, tag),
        ),
        SheetAction(
          icon: Icons.palette_outlined,
          label: '色を変更',
          onTap: () => _pickColor(context, ref, tag),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => _delete(context, ref, tag),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Tag tag) async {
    final name = await AppDialogs.prompt(context,
        title: 'タグ名変更',
        initialValue: tag.name,
        hintText: 'タグ名',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    ref.read(tagsProvider.notifier).rename(tag.id, name);
  }

  /// 全曲からこのタグが外れて戻せないので、使われている曲数を出して確認する
  Future<void> _delete(BuildContext context, WidgetRef ref, Tag tag) async {
    final used = ref
        .read(loopItemsProvider)
        .where((i) => i.tagIds.contains(tag.id))
        .length;
    final ok = await AppDialogs.confirmDelete(context,
        title: 'タグを削除',
        message: used == 0
            ? 'タグ「${tag.name}」を削除しますか？'
            : 'タグ「${tag.name}」を削除しますか？'
                '\n$used 曲からこのタグが外れます（曲は残ります）');
    if (!ok) return;
    ref
        .read(tagFilterProvider.notifier)
        .update((s) => Map<String, bool>.from(s)..remove(tag.id));
    ref.read(tagsProvider.notifier).delete(tag.id);
    ref.read(loopItemsProvider.notifier).removeTagFromAll(tag.id);
  }

  void _pickColor(BuildContext context, WidgetRef ref, Tag tag) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('「${tag.name}」の色',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < tagPresetColors.length; i++)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        ref.read(tagsProvider.notifier).setColor(tag.id, i);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: tagPresetColors[i],
                          shape: BoxShape.circle,
                          border: tag.colorIndex == i
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                        ),
                        child: i == 0
                            ? Center(
                                child: Text('D',
                                    style: Theme.of(ctx)
                                        .textTheme
                                        .bodyLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white)))
                            : null,
                      ),
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
