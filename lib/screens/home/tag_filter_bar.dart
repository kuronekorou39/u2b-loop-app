import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/item_filter.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/glass_panel.dart';
import '../../widgets/tag_chip.dart';

/// タグ絞り込みのシート（3 状態: 含む / 除外 / なし）を開く。結果は [tagFilterProvider] へ。
/// [onClosed] はシートを閉じたあと（検索欄のフォーカスを外すなど）
Future<void> showTagFilterSheet(BuildContext context, WidgetRef ref, List<Tag> tags,
    {VoidCallback? onClosed}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _TagFilterSheet(tags: tags, initial: ref.read(tagFilterProvider)),
  ).then((_) => onClosed?.call());
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
          // 見出し・凡例・クリアは 1 行。クリアは隠すだけで場所を残す（選んでも下の一覧がずれない）
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.md, AppSpacing.sm),
            child: Row(
              children: [
                Text('タグフィルター', style: textTheme.titleMedium),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Wrap(
                    spacing: AppSpacing.md,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _legend(Icons.check_circle, AppTheme.accentGreen, '含む'),
                      _legend(Icons.remove_circle, AppTheme.accentRed, '除外'),
                      _legend(Icons.radio_button_unchecked,
                          AppTheme.muted(context), 'なし'),
                    ],
                  ),
                ),
                Visibility(
                  visible: _selected.isNotEmpty,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: TextButton(
                    onPressed: () {
                      ref.read(tagFilterProvider.notifier).state = {};
                      Navigator.pop(context);
                    },
                    child: Text('クリア', style: textTheme.bodyMedium),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              // 一番下までスクロールしても、最後の行が画面の下端（フッター）に付かないように
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
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
        ],
      ),
    );
  }

  Widget _legend(IconData icon, Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: AppIconSizes.xs),
          const SizedBox(width: 2),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

/// タグ絞り込みの 1 行: 頭の絞り込みボタン（シートを開く）、絞り込み中のタグ（× で外す）、「クリア」。
/// タグを選んでも選ばなくても同じ高さで出す（選ぶたびに一覧が下がらないように）
class SelectedTagBar extends ConsumerWidget {
  const SelectedTagBar({super.key, required this.tags, this.onClosed});

  final List<Tag> tags;

  /// シートを閉じたあと
  final VoidCallback? onClosed;

  static const height = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(tagFilterProvider);
    final active = filter.isNotEmpty;
    final textTheme = Theme.of(context).textTheme;
    void open() => showTagFilterSheet(context, ref, tags, onClosed: onClosed);

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
      height: height,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.xs, AppSpacing.sm, AppSpacing.xs),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: GlassPill(
                    active: active,
                    tooltip: 'タグフィルター',
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                    onTap: open,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.filter_alt_outlined,
                            size: AppIconSizes.s,
                            color: active ? AppTheme.accentGreen : null),
                        if (!active) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Text('タグで絞り込み', style: textTheme.labelMedium),
                        ],
                      ],
                    ),
                  ),
                ),
                if (filter.containsKey(ItemFilter.untaggedId))
                  chip(Tag(id: ItemFilter.untaggedId, name: '未分類'),
                      filter[ItemFilter.untaggedId]!),
                for (final tag in tags)
                  if (filter.containsKey(tag.id)) chip(tag, filter[tag.id]!),
              ],
            ),
          ),
          Visibility(
            visible: active,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: TextButton(
              onPressed: () => ref.read(tagFilterProvider.notifier).state = {},
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              ),
              child: Text('クリア',
                  style: textTheme.labelSmall!
                      .copyWith(color: AppTheme.accentGreen)),
            ),
          ),
        ],
      ),
    );
  }
}
