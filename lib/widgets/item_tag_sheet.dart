import 'package:flutter/material.dart';

import '../models/loop_item.dart';
import '../models/tag.dart';

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
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいタグ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('作成して追加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      final tag = await widget.onCreateAndAdd(name);
      setState(() {
        _tags.add(tag);
        _activeTagIds.add(tag.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('タグを選択',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            if (_tags.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('タグがありません',
                    style: TextStyle(color: Colors.grey)),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final tag in _tags)
                    CheckboxListTile(
                      title: Text(tag.name,
                          style: const TextStyle(fontSize: 14)),
                      value: _activeTagIds.contains(tag.id),
                      onChanged: (_) => _toggle(tag.id),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _createNew,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新しいタグを作成して追加'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
