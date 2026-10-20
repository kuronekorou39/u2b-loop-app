import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/tag.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/tag_chip.dart';

/// プレイリストに入れる曲を一覧から選ぶ画面（ガラス風）。
///
/// 検索欄とタグの絞り込み（チップのタップで切替）の下に、1 枚のガラス面の一覧。
/// 区間のある曲は行を開いて区間ごとに選べる（「全体」も 1 つの区間として扱う）。
/// 決定は右上の「追加 (n)」。
class PlaylistItemPickerScreen extends StatefulWidget {
  const PlaylistItemPickerScreen({
    super.key,
    required this.items,
    required this.tags,
    required this.existingIds,
    required this.onAdd,
  });

  final List<LoopItem> items;
  final List<Tag> tags;

  /// すでにプレイリストに入っている曲（選べない）
  final Set<String> existingIds;

  /// 追加する曲の ID と、区間のある曲の区間 ID（全区間なら省略）
  final void Function(List<String> ids, Map<String, List<String>> regions)
      onAdd;

  /// 「全体」を表す区間 ID（playlist_player_provider と同じ文字列）
  static const fullTrackId = '__full__';

  @override
  State<PlaylistItemPickerScreen> createState() =>
      _PlaylistItemPickerScreenState();
}

class _PlaylistItemPickerScreenState extends State<PlaylistItemPickerScreen> {
  /// itemId → 選んだ regionId。キーがあれば曲を選んでいる。
  /// 空の Set は区間のない曲
  final Map<String, Set<String>> _selections = {};
  final Set<String> _expanded = {};
  final Set<String> _filterTagIds = {};
  final _searchController = TextEditingController();
  String _searchQuery = '';

  int get _selectedCount => _selections.length;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _hasRegions(LoopItem item) => item.effectiveRegions.isNotEmpty;

  void _toggleItem(LoopItem item) {
    setState(() {
      if (_selections.containsKey(item.id)) {
        _selections.remove(item.id);
        _expanded.remove(item.id);
      } else if (_hasRegions(item)) {
        // 区間付き: 全区間を選んで開く（「全体」は含めない）
        _selections[item.id] = item.effectiveRegions.map((r) => r.id).toSet();
        _expanded.add(item.id);
      } else {
        _selections[item.id] = {};
      }
    });
  }

  void _toggleRegion(LoopItem item, String regionId) {
    setState(() {
      final sel = _selections[item.id];
      if (sel == null) return;
      if (sel.contains(regionId)) {
        sel.remove(regionId);
        // 区間を全部外したら曲ごと外す
        if (sel.isEmpty) {
          _selections.remove(item.id);
          _expanded.remove(item.id);
        }
      } else {
        sel.add(regionId);
      }
    });
  }

  void _submit() {
    final ids = <String>[];
    final regions = <String, List<String>>{};
    for (final entry in _selections.entries) {
      ids.add(entry.key);
      if (entry.value.isNotEmpty) regions[entry.key] = entry.value.toList();
    }
    widget.onAdd(ids, regions);
    Navigator.pop(context);
  }

  List<LoopItem> _visibleItems() {
    var items = widget.items;
    if (_filterTagIds.isNotEmpty) {
      items = items
          .where((i) => _filterTagIds.every((t) => i.tagIds.contains(t)))
          .toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      items = items.where((i) => i.title.toLowerCase().contains(q)).toList();
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final items = _visibleItems();
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;

    return GlassScaffold(
      title: Text('曲を選択', style: textTheme.titleMedium),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.lg),
          child: Center(
            child: GreenButton(
              icon: Icons.playlist_add,
              label: '追加 ($_selectedCount)',
              size: 36,
              onPressed: _selectedCount == 0 ? null : _submit,
            ),
          ),
        ),
      ],
      // 上端の余白は Scaffold の中の context から（State の context だと
      // 状態バーの分しか入らず、検索欄が AppBar の裏に隠れていた）
      bodyBuilder: (context) => Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: GlassSearchField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          if (widget.tags.isNotEmpty) _buildTagFilter(),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      widget.items.isEmpty ? '追加できる曲がありません' : '該当する曲がありません',
                      style: textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5)),
                    ),
                  )
                : GlassSurface(
                    margin: EdgeInsets.fromLTRB(AppSpacing.lg, 0,
                        AppSpacing.lg, bottomPad + AppSpacing.lg),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.xs),
                        itemCount: items.length,
                        itemBuilder: (context, i) => _buildItemTile(items[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// タグのチップを横に並べ、タップで絞り込みの入切。選んでいないものは薄く
  Widget _buildTagFilter() {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
        children: [
          for (final tag in widget.tags)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Opacity(
                opacity: _filterTagIds.contains(tag.id) ? 1 : 0.45,
                child: TagChip(
                  tag: tag,
                  onTap: () => setState(() {
                    if (!_filterTagIds.remove(tag.id)) {
                      _filterTagIds.add(tag.id);
                    }
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildItemTile(LoopItem item) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final alreadyIn = widget.existingIds.contains(item.id);
    final isSelected = _selections.containsKey(item.id);
    final hasRegions = _hasRegions(item);
    final isExpanded = _expanded.contains(item.id);
    final regions = item.effectiveRegions;
    final selectedRegions = _selections[item.id];

    // 区間の一部だけ選んでいるときは中間状態（null）
    bool? checkValue;
    if (alreadyIn) {
      checkValue = true;
    } else if (!isSelected) {
      checkValue = false;
    } else if (hasRegions && selectedRegions != null) {
      checkValue = selectedRegions.length == regions.length ? true : null;
    } else {
      checkValue = true;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          selected: isSelected,
          selectedTileColor: AppTheme.accentGreen.withValues(alpha: 0.10),
          selectedColor: Theme.of(context).colorScheme.onSurface,
          leading: ClipRRect(
            borderRadius: AppRadius.borderXs,
            child: SizedBox(
              width: 64,
              height: 36,
              child: ItemThumbnail(item: item, iconSize: AppIconSizes.sm),
            ),
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyLarge?.copyWith(color: alreadyIn ? dim : null),
          ),
          subtitle: alreadyIn
              ? Text('追加済み', style: textTheme.labelSmall)
              : hasRegions
                  ? Text('${regions.length + 1} 区間（全体含む）',
                      style: textTheme.labelSmall)
                  : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasRegions && !alreadyIn)
                IconButton(
                  icon: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: AppIconSizes.lg,
                      color: dim),
                  tooltip: isExpanded ? '区間を閉じる' : '区間を開く',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    if (!_expanded.remove(item.id)) _expanded.add(item.id);
                  }),
                ),
              Checkbox(
                value: checkValue,
                tristate: true,
                onChanged: alreadyIn ? null : (_) => _toggleItem(item),
              ),
            ],
          ),
          onTap: alreadyIn ? null : () => _toggleItem(item),
        ),
        if (isExpanded && hasRegions && !alreadyIn) ...[
          _RegionRow(
            name: '全体',
            time: '区間を使わず全体を再生',
            value: selectedRegions?.contains(
                    PlaylistItemPickerScreen.fullTrackId) ??
                false,
            onChanged: isSelected
                ? () => _toggleRegion(
                    item, PlaylistItemPickerScreen.fullTrackId)
                : null,
          ),
          for (final region in regions)
            _RegionRow(
              name: region.name,
              time: _formatRegionTime(region),
              value: selectedRegions?.contains(region.id) ?? false,
              onChanged:
                  isSelected ? () => _toggleRegion(item, region.id) : null,
            ),
        ],
      ],
    );
  }

  String? _formatRegionTime(LoopRegion region) {
    if (!region.hasPoints) return null;
    return '${TimeUtils.formatShortMs(region.pointAMs)}'
        ' - ${TimeUtils.formatShortMs(region.pointBMs)}';
  }
}

/// 「曲を追加」で選ぶ入口
enum PlaylistAddChoice { pick, byTag }

/// 「曲を追加」の入口を選ぶダイアログ（他の「追加」と同じく画面の中央に出す）
Future<PlaylistAddChoice?> showPlaylistAddDialog(BuildContext context) {
  final textTheme = Theme.of(context).textTheme;
  return showDialog<PlaylistAddChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('曲を追加', style: textTheme.displaySmall),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist, color: AppTheme.accentGreen),
              title: Text('一覧から選択', style: textTheme.bodyLarge),
              subtitle: Text('検索・タグで絞り込んで曲ごとに選ぶ',
                  style: textTheme.bodySmall),
              onTap: () => Navigator.pop(ctx, PlaylistAddChoice.pick),
            ),
            ListTile(
              leading:
                  const Icon(Icons.label_outline, color: AppTheme.accentGreen),
              title: Text('タグで自動追加', style: textTheme.bodyLarge),
              subtitle: Text('タグの付いた曲が入り、後からタグを付けた曲も入る',
                  style: textTheme.bodySmall),
              onTap: () => Navigator.pop(ctx, PlaylistAddChoice.byTag),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 「タグで自動追加」の結果
typedef PlaylistTagsResult = ({List<String> tagIds, bool restoreExcluded});

/// プレイリストに自動で入れるタグを選ぶダイアログ（複数選べる。どれか 1 つが付いた曲が入る）。
/// タグが多くても中で縦に流れる。[countOf] はそのタグが付いた曲数。
/// [excludedCount] は外した曲の数（1 以上なら「戻す」を出す）
Future<PlaylistTagsResult?> showPlaylistTagsDialog(
  BuildContext context, {
  required List<Tag> tags,
  required Set<String> selected,
  required int Function(Tag tag) countOf,
  int excludedCount = 0,
}) {
  return showDialog<PlaylistTagsResult>(
    context: context,
    builder: (_) => _PlaylistTagsDialog(
      tags: tags,
      initial: selected,
      countOf: countOf,
      excludedCount: excludedCount,
    ),
  );
}

class _PlaylistTagsDialog extends StatefulWidget {
  const _PlaylistTagsDialog({
    required this.tags,
    required this.initial,
    required this.countOf,
    required this.excludedCount,
  });

  final List<Tag> tags;
  final Set<String> initial;
  final int Function(Tag tag) countOf;
  final int excludedCount;

  @override
  State<_PlaylistTagsDialog> createState() => _PlaylistTagsDialogState();
}

class _PlaylistTagsDialogState extends State<_PlaylistTagsDialog> {
  late final Set<String> _selected = {...widget.initial};
  bool _restoreExcluded = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
    // タグ一覧の並び（ユーザーが決めた順）のまま
    final tags = widget.tags;
    return AlertDialog(
      title: Text('タグで自動追加', style: textTheme.displaySmall),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      content: SizedBox(
        width: double.maxFinite,
        child: tags.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('タグがありません',
                    style: textTheme.bodyMedium?.copyWith(color: dim)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: tags.length,
                      itemBuilder: (_, i) {
                        final tag = tags[i];
                        final on = _selected.contains(tag.id);
                        return CheckboxListTile(
                          value: on,
                          onChanged: (_) => setState(() => on
                              ? _selected.remove(tag.id)
                              : _selected.add(tag.id)),
                          secondary: Icon(Icons.label,
                              size: AppIconSizes.md, color: tag.color),
                          title: Text(tag.name, style: textTheme.bodyLarge),
                          subtitle: Text('${widget.countOf(tag)} 曲',
                              style: textTheme.labelSmall),
                        );
                      },
                    ),
                  ),
                  if (widget.excludedCount > 0)
                    CheckboxListTile(
                      value: _restoreExcluded,
                      onChanged: (v) =>
                          setState(() => _restoreExcluded = v ?? false),
                      title: Text('外した ${widget.excludedCount} 曲を戻す',
                          style: textTheme.bodyMedium),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop<PlaylistTagsResult>(context, (
            // タグ一覧の並びで保存
            tagIds: [for (final t in tags) if (_selected.contains(t.id)) t.id],
            restoreExcluded: _restoreExcluded,
          )),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// 曲の行の下に字下げして出す区間の行
class _RegionRow extends StatelessWidget {
  const _RegionRow({
    required this.name,
    required this.time,
    required this.value,
    required this.onChanged,
  });

  final String name;
  final String? time;
  final bool value;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 80),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        title: Text(name, style: textTheme.bodyMedium),
        subtitle: time != null ? Text(time!, style: textTheme.labelSmall) : null,
        trailing: Checkbox(
          value: value,
          onChanged: onChanged == null ? null : (_) => onChanged!(),
          visualDensity: VisualDensity.compact,
        ),
        onTap: onChanged,
      ),
    );
  }
}
