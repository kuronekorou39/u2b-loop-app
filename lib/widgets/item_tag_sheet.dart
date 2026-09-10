import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import '../models/tag.dart';
import '../core/ui/app_dialogs.dart';

/// 個別アイテムのタグ編集シート（共有ウィジェット）
class ItemTagSheet extends StatefulWidget {
  final List<Tag> tags;
  final LoopItem item;
  final void Function(String tagId, bool add) onToggle;
  final Future<Tag> Function(String name) onCreateAndAdd;

  const ItemTagSheet({
    super.key,
    required this.tags,
    required this.item,
    required this.onToggle,
    required this.onCreateAndAdd,
  });

  @override
  State<ItemTagSheet> createState() => _ItemTagSheetState();
}

class _ItemTagSheetState extends State<ItemTagSheet> {
  late Set<String> _activeTagIds;
  late List<Tag> _tags;

  @override
  void initState() {
    super.initState();
    _activeTagIds = Set.from(widget.item.tagIds);
    _tags = List.from(widget.tags);
  }

  void _toggle(String tagId) {
    setState(() {
      if (_activeTagIds.contains(tagId)) {
        _activeTagIds.remove(tagId);
        widget.onToggle(tagId, false);
      } else {
        _activeTagIds.add(tagId);
        widget.onToggle(tagId, true);
      }
    });
  }

  void _createNew() async {
    final name = await AppDialogs.prompt(context,
        title: '新しいタグ',
        hintText: 'タグ名',
        confirmLabel: '作成して追加',
        maxLength: AppLimits.tagNameMaxLength);
    if (name != null) {
      final tag = await widget.onCreateAndAdd(name);
      setState(() {
        _tags.add(tag);
        _activeTagIds.add(tag.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl, vertical: AppSpacing.md),
              child: Text('タグを選択', style: textTheme.titleMedium),
            ),
            const Divider(height: 1),
            if (_tags.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('タグがありません', style: textTheme.bodyMedium!
                    .copyWith(color: textTheme.bodySmall!.color)),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final tag in _tags)
                    CheckboxListTile(
                      title: Text(tag.name, style: textTheme.bodyLarge),
                      value: _activeTagIds.contains(tag.id),
                      onChanged: (_) => _toggle(tag.id),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl, vertical: AppSpacing.xs),
              child: OutlinedButton.icon(
                onPressed: _createNew,
                icon: const Icon(Icons.add, size: AppIconSizes.sm),
                label: const Text('新しいタグを作成して追加'),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}
