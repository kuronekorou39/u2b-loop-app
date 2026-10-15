import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_surface.dart';
import 'home_parts.dart';

/// ホームの「タグ」タブ。タグの一覧（リスト / グリッド）と、名前・色の変更、削除。
///
/// 行をタップすると [onTagTap]（曲タブへ移ってそのタグで絞り込む）。
/// 複数選択中（[selecting]）はタップで選択の切替、操作はホームの選択バー側
class TagManagerTab extends ConsumerWidget {
  const TagManagerTab({
    super.key,
    required this.onTagTap,
    this.grid = false,
    this.selecting = false,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onLongPress,
  });

  final ValueChanged<Tag> onTagTap;

  /// グリッド表示（色つきのチップを並べる）
  final bool grid;
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<Tag>? onToggleSelect;
  final ValueChanged<Tag>? onLongPress;

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

  /// まとめて削除（選択バーから）。使われている曲数を出して確認する。戻り値は消したか
  static Future<bool> deleteTags(
      BuildContext context, WidgetRef ref, List<Tag> tags) async {
    if (tags.isEmpty) return false;
    final items = ref.read(loopItemsProvider);
    final ids = tags.map((t) => t.id).toSet();
    final used = items.where((i) => i.tagIds.any(ids.contains)).length;
    final name = tags.length == 1 ? 'タグ「${tags.first.name}」' : 'タグ ${tags.length} 件';
    final ok = await AppDialogs.confirmDelete(context,
        title: 'タグを削除',
        message: used == 0
            ? '$nameを削除しますか？'
            : '$nameを削除しますか？\n$used 曲からこのタグが外れます（曲は残ります）');
    if (!ok) return false;
    ref.read(tagFilterProvider.notifier).update(
        (s) => Map<String, bool>.from(s)..removeWhere((k, _) => ids.contains(k)));
    for (final tag in tags) {
      await ref.read(tagsProvider.notifier).delete(tag.id);
      await ref.read(loopItemsProvider.notifier).removeTagFromAll(tag.id);
    }
    return true;
  }

  /// 色を選ぶシート。[current] は選択中の色番号（複数のときは null）
  static Future<int?> pickColor(BuildContext context,
      {required String title, int? current}) {
    return showModalBottomSheet<int>(
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
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < tagPresetColors.length; i++)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(ctx, i),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: tagPresetColors[i],
                          shape: BoxShape.circle,
                          border: current == i
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

  /// まとめて色を変える（選択バーから）
  static Future<void> recolorTags(
      BuildContext context, WidgetRef ref, List<Tag> tags) async {
    if (tags.isEmpty) return;
    final same = tags.every((t) => t.colorIndex == tags.first.colorIndex);
    final picked = await pickColor(context,
        title: tags.length == 1 ? '「${tags.first.name}」の色' : '${tags.length} 件の色',
        current: same ? tags.first.colorIndex : null);
    if (picked == null) return;
    for (final tag in tags) {
      ref.read(tagsProvider.notifier).setColor(tag.id, picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    final allItems = ref.watch(loopItemsProvider);

    if (tags.isEmpty) {
      return const EmptyHint(
          icon: Icons.label_outline, title: 'タグがありません', subtitle: '＋ ボタンで作成');
    }

    int countOf(Tag tag) =>
        allItems.where((item) => item.tagIds.contains(tag.id)).length;

    void tap(Tag tag) {
      if (selecting) {
        onToggleSelect?.call(tag);
      } else {
        onTagTap(tag);
      }
    }

    if (grid) return _buildGrid(context, ref, tags, countOf, tap);

    final textTheme = Theme.of(context).textTheme;
    return HomeListSurface(
      child: ListView.builder(
        padding: HomeListSurface.listPadding,
        itemCount: tags.length,
        itemBuilder: (context, i) {
          final tag = tags[i];
          final selected = selectedIds.contains(tag.id);
          return ListTile(
            selected: selected,
            leading: selecting
                ? Checkbox(
                    value: selected,
                    onChanged: (_) => onToggleSelect?.call(tag),
                    visualDensity: VisualDensity.compact,
                  )
                : _TagDot(tag: tag),
            title: Text(tag.name, style: textTheme.bodyLarge),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${countOf(tag)} 曲', style: textTheme.bodySmall),
                if (!selecting)
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: AppIconSizes.md),
                    tooltip: 'メニュー',
                    onPressed: () => _showMenu(context, ref, tag),
                  ),
              ],
            ),
            onTap: () => tap(tag),
            onLongPress: () => onLongPress?.call(tag),
          );
        },
      ),
    );
  }

  /// グリッド: 色つきのチップ（名前・曲数）。選択中は緑の面 + チェック
  Widget _buildGrid(BuildContext context, WidgetRef ref, List<Tag> tags,
      int Function(Tag) countOf, void Function(Tag) tap) {
    final textTheme = Theme.of(context).textTheme;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisExtent: 56,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md,
      ),
      itemCount: tags.length,
      itemBuilder: (context, i) {
        final tag = tags[i];
        final selected = selectedIds.contains(tag.id);
        return GlassSurface(
          radius: 14,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          tint: selected
              ? AppTheme.accentGreen.withValues(alpha: 0.15)
              : tag.color.withValues(alpha: 0.12),
          onTap: () => tap(tag),
          onLongPress: () => onLongPress?.call(tag),
          child: Row(
            children: [
              if (selecting)
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: AppIconSizes.md,
                  color: selected
                      ? AppTheme.accentGreen
                      : AppTheme.muted(context),
                )
              else
                _TagDot(tag: tag),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tag.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text('${countOf(tag)} 曲', style: textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
          onTap: () => recolorTags(context, ref, [tag]),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => deleteTags(context, ref, [tag]),
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
}

/// タグの色の丸（中にラベルのアイコン）
class _TagDot extends StatelessWidget {
  const _TagDot({required this.tag});

  final Tag tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppIconSizes.lg,
      height: AppIconSizes.lg,
      decoration: BoxDecoration(
        color: tag.color.withValues(alpha: 0.25),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.label, size: AppIconSizes.xs, color: tag.color),
    );
  }
}
