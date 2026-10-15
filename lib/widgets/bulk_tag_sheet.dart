import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_dialogs.dart';
import '../models/loop_item.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';

/// 複数選択した曲にタグをまとめて付け外しするシート。
///
/// 各タグは 3 状態のチェック（✓ = 全員に付いている、□ = 誰にも無い、ー = 一部）。
/// タップで ✓ なら全外し、それ以外は全付け。変更は即座に保存される
class BulkTagSheet extends StatefulWidget {
  const BulkTagSheet({
    super.key,
    required this.tags,
    required this.selectedItems,
    required this.allItems,
    required this.onAddTag,
    required this.onRemoveTag,
    required this.onClearTags,
    required this.onCreateTag,
  });

  final List<Tag> tags;
  final List<LoopItem> selectedItems;
  final List<LoopItem> allItems;
  final void Function(String tagId) onAddTag;
  final void Function(String tagId) onRemoveTag;
  final VoidCallback onClearTags;
  final Future<Tag> Function(String name) onCreateTag;

  /// 選んだ曲 ID に対して開く（プロバイダの読み書きはここで結線する）
  static Future<void> show(
      BuildContext context, WidgetRef ref, List<String> itemIds) {
    final items = ref.read(loopItemsProvider);
    final notifier = ref.read(loopItemsProvider.notifier);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => BulkTagSheet(
        tags: ref.read(tagsProvider),
        selectedItems: items.where((i) => itemIds.contains(i.id)).toList(),
        allItems: items,
        onAddTag: (tagId) => notifier.addTagToItems(itemIds, tagId),
        onRemoveTag: (tagId) => notifier.removeTagFromItems(itemIds, tagId),
        onClearTags: () => notifier.clearTagsFromItems(itemIds),
        onCreateTag: (name) => ref.read(tagsProvider.notifier).create(name),
      ),
    );
  }

  @override
  State<BulkTagSheet> createState() => _BulkTagSheetState();
}

class _BulkTagSheetState extends State<BulkTagSheet> {
  late List<Tag> _tags;

  // タグごとの適用状態: true=全員付与, false=全員なし, 未登録=初期（実データ参照）
  final Map<String, bool> _tagState = {};

  @override
  void initState() {
    super.initState();
    _tags = List.from(widget.tags);
  }

  /// 表示用の値: true=✓, false=□, null=ー
  bool? _displayValue(String tagId) {
    if (_tagState.containsKey(tagId)) return _tagState[tagId];
    final all = widget.selectedItems.every((i) => i.tagIds.contains(tagId));
    if (all) return true;
    final some = widget.selectedItems.any((i) => i.tagIds.contains(tagId));
    if (some) return null;
    return false;
  }

  void _showNewTagInput() async {
    final name = await AppDialogs.prompt(context,
        title: '新しいタグ',
        hintText: 'タグ名',
        confirmLabel: '作成',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    final tag = await widget.onCreateTag(name);
    widget.onAddTag(tag.id);
    if (!mounted) return;
    setState(() {
      _tags.add(tag);
      _tagState[tag.id] = true;
    });
  }

  Future<void> _clearAll() async {
    final ok = await AppDialogs.confirm(context,
        title: 'タグをすべて解除',
        message: '選んだ ${widget.selectedItems.length} 件からタグをすべて外しますか？',
        confirmLabel: '解除',
        destructive: true);
    if (!ok || !mounted) return;
    widget.onClearTags();
    setState(() {
      for (final t in _tags) {
        _tagState[t.id] = false;
      }
    });
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
                Text('タグ（${widget.selectedItems.length}件に適用）',
                    style: textTheme.titleMedium),
                const Spacer(),
                if (_tags.isNotEmpty)
                  TextButton(
                    onPressed: _clearAll,
                    child: Text('すべて解除', style: textTheme.labelMedium),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_tags.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text('タグがありません',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: AppTheme.muted(context))),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final tag in _tags)
                  CheckboxListTile(
                    title: Text(tag.name, style: textTheme.bodyLarge),
                    subtitle: Text(
                      '${widget.allItems.where((i) => i.tagIds.contains(tag.id)).length} 曲',
                      style: textTheme.labelSmall
                          ?.copyWith(color: AppTheme.muted(context)),
                    ),
                    secondary: Icon(Icons.label,
                        size: AppIconSizes.md, color: tag.color),
                    value: _displayValue(tag.id),
                    tristate: true,
                    onChanged: (_) {
                      if (_displayValue(tag.id) == true) {
                        // ✓ → 全外し
                        widget.onRemoveTag(tag.id);
                        setState(() => _tagState[tag.id] = false);
                      } else {
                        // □ or ー → 全付け
                        widget.onAddTag(tag.id);
                        setState(() => _tagState[tag.id] = true);
                      }
                    },
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add, size: AppIconSizes.md),
            title: Text('新しいタグを作成', style: textTheme.bodyLarge),
            onTap: _showNewTagInput,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
