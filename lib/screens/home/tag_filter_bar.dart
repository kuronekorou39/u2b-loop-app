import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/item_filter.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/glass_panel.dart';
import '../../widgets/tag_chip.dart';

/// ホームの検索行にあるタグ絞り込みのボタン（件数バッジ付き）。
/// タップで 3 状態（含む / 除外 / なし）のシートを開く。結果は [tagFilterProvider] へ
class TagFilterButton extends ConsumerWidget {
  const TagFilterButton({super.key, required this.tags, this.onClosed});

  final List<Tag> tags;

  /// シートを閉じたあと（検索欄のフォーカスを外すなど）
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(tagFilterProvider);
    final active = filter.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GlassPill(
          active: active,
          tooltip: 'タグフィルター',
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.filter_alt_outlined,
              size: AppIconSizes.md,
              color: active ? AppTheme.accentGreen : null),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => _TagFilterSheet(tags: tags, initial: filter),
          ).then((_) => onClosed?.call()),
        ),
        if (active)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.xs),
              decoration: const BoxDecoration(
                color: AppTheme.accentGreen,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${filter.length}',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall!
                    .copyWith(color: Colors.black),
              ),
            ),
          ),
      ],
    );
  }
}

class _TagFilterSheet extends ConsumerStatefulWidget {
  const _TagFilterSheet({required this.tags, required this.initial});

  final List<Tag> tags;
  final Map<String, bool> initial;

  @override
  ConsumerState<_TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends ConsumerState<_TagFilterSheet> {
  // null=off, true=含む, false=除外
  late final Map<String, bool?> _selected = Map.from(widget.initial);

  /// 3ステート: off → 含む → 除外 → off
  void _cycle(String id) {
    setState(() {
      final current = _selected[id];
      if (current == null) {
        _selected[id] = true;
      } else if (current) {
        _selected[id] = false;
      } else {
        _selected.remove(id);
      }
    });
    ref.read(tagFilterProvider.notifier).state = {
      for (final e in _selected.entries)
        if (e.value != null) e.key: e.value!,
    };
  }

  Widget _tile({required String id, required String title, Widget? leading}) {
    final state = _selected[id];
    final Icon icon;
    final Color? titleColor;
    if (state == true) {
      icon = const Icon(Icons.check_circle,
          color: AppTheme.accentGreen, size: AppIconSizes.md);
      titleColor = null;
    } else if (state == false) {
      icon = const Icon(Icons.remove_circle,
          color: AppTheme.accentRed, size: AppIconSizes.md);
      titleColor = AppTheme.accentRed;
    } else {
      icon = Icon(Icons.radio_button_unchecked,
          color: AppTheme.muted(context), size: AppIconSizes.md);
      titleColor = null;
    }
    return ListTile(
      leading: leading,
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
              color: titleColor,
              decoration: state == false ? TextDecoration.lineThrough : null,
            ),
      ),
      trailing: icon,
      onTap: () => _cycle(id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.md),
            child: Row(
              children: [
                Text('タグフィルター', style: textTheme.titleMedium),
                const Spacer(),
                if (_selected.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      ref.read(tagFilterProvider.notifier).state = {};
                      Navigator.pop(context);
                    },
                    child: Text('クリア', style: textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Row(
              children: [
                const Icon(Icons.check_circle,
                    color: AppTheme.accentGreen, size: AppIconSizes.xs),
                Text(' 含む', style: textTheme.labelSmall),
                const SizedBox(width: AppSpacing.lg),
                const Icon(Icons.remove_circle,
                    color: AppTheme.accentRed, size: AppIconSizes.xs),
                Text(' 除外', style: textTheme.labelSmall),
                const SizedBox(width: AppSpacing.lg),
                Icon(Icons.radio_button_unchecked,
                    color: AppTheme.muted(context), size: AppIconSizes.xs),
                Text(' なし', style: textTheme.labelSmall),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _tile(
                  id: ItemFilter.untaggedId,
                  title: '未分類',
                  leading: const Icon(Icons.label_off, size: AppIconSizes.md),
                ),
                for (final tag in widget.tags)
                  _tile(id: tag.id, title: tag.name),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

/// 絞り込み中のタグ（× で外す）と「クリア」の 1 行
class SelectedTagBar extends ConsumerWidget {
  const SelectedTagBar({super.key, required this.tags});

  final List<Tag> tags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(tagFilterProvider);

    Widget chip(Tag tag, bool include) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: TagChip(
            tag: tag,
            excluded: !include,
            onDeleted: () => ref.read(tagFilterProvider.notifier).update(
                (s) => Map<String, bool>.from(s)..remove(tag.id)),
          ),
        );

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.fromLTRB(AppSpacing.lg, 6, AppSpacing.sm, 6),
              children: [
                if (filter.containsKey(ItemFilter.untaggedId))
                  chip(Tag(id: ItemFilter.untaggedId, name: '未分類'),
                      filter[ItemFilter.untaggedId]!),
                for (final tag in tags)
                  if (filter.containsKey(tag.id)) chip(tag, filter[tag.id]!),
              ],
            ),
          ),
          TextButton(
            onPressed: () => ref.read(tagFilterProvider.notifier).state = {},
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
            child: Text('クリア',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall!
                    .copyWith(color: AppTheme.accentGreen)),
          ),
        ],
      ),
    );
  }
}
