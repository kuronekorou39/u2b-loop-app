import 'dart:math';

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
/// 検索欄とタグの絞り込み（チップのタップで切替。選んだタグのどれかが付いた曲 = OR。
/// 曲一覧の絞り込みと同じ）の下に、1 枚のガラス面の一覧。
/// 区間のある曲は行を開いて区間ごとに選べる（「全体」も 1 つの区間として扱う）。
/// 決定は右上の「追加 (n)」。その左に、表示中の曲をまとめて選ぶ・外すボタン。
/// 横画面は左右（ナビゲーションバー・カメラの切り欠き）と下の画面の端を避ける
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

  /// 表示中（検索・タグで絞った）の曲のうち、まだプレイリストに入っていないもの
  List<LoopItem> _selectable(List<LoopItem> visible) =>
      [for (final i in visible) if (!widget.existingIds.contains(i.id)) i];

  /// 表示中の曲をまとめて選ぶ。全部選んであれば外す（区間のある曲は全区間、開かない）
  void _toggleSelectAll(List<LoopItem> visible) {
    final targets = _selectable(visible);
    final all = targets.every((i) => _selections.containsKey(i.id));
    setState(() {
      for (final item in targets) {
        if (all) {
          _selections.remove(item.id);
          _expanded.remove(item.id);
        } else {
          _selections.putIfAbsent(
              item.id,
              () => _hasRegions(item)
                  ? item.effectiveRegions.map((r) => r.id).toSet()
                  : <String>{});
        }
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
    // 選んだタグのどれかが付いた曲（OR。曲一覧の絞り込みと同じ。ここでは除外は無い）
    if (_filterTagIds.isNotEmpty) {
      items = items
          .where((i) => i.tagIds.any(_filterTagIds.contains))
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
    final selectable = _selectable(items);
    final allSelected = selectable.isNotEmpty &&
        selectable.every((i) => _selections.containsKey(i.id));

    return GlassScaffold(
      title: Text('曲を選択', style: textTheme.titleMedium),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          // 表示中（検索・タグで絞った）の曲が対象。ほかの一覧の「全選択」と同じアイコン
          tooltip: allSelected ? '全解除' : '全選択',
          onPressed:
              selectable.isEmpty ? null : () => _toggleSelectAll(items),
        ),
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
      // 状態バーの分しか入らず、検索欄が AppBar の裏に隠れていた）。
      // 左右と下は画面の端（横画面のナビゲーションバー・切り欠き、下のジェスチャーの帯）を避ける
      bodyBuilder: (context) {
        final view = MediaQuery.viewPaddingOf(context);
        final left = AppSpacing.lg + view.left;
        final right = AppSpacing.lg + view.right;
        return Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + AppSpacing.xs),
          Padding(
            padding: EdgeInsets.only(left: left, right: right),
            child: GlassSearchField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          if (widget.tags.isNotEmpty) _buildTagFilter(left: left, right: right),
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
                    margin: EdgeInsets.fromLTRB(
                        left, 0, right, view.bottom + AppSpacing.lg),
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
      );
      },
    );
  }

  /// タグのチップを横に並べ、タップで絞り込みの入切。選んでいないものは薄く
  Widget _buildTagFilter({required double left, required double right}) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(left, AppSpacing.md, right, 0),
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

/// プレイリストに自動で入れるタグを選ぶダイアログ（複数選べる。どれか 1 つが付いた曲が入る）。
/// 選んだタグとほかのタグを分けて出す（縦は上に選んだタグ・区切りの線・ほかのタグ、横は左右の列）。
/// どちらもタグ一覧の並び。行にはタグのサムネ（[thumbOf]）と曲数（[countOf]）。
/// 戻り値は選んだタグの ID（タグ一覧の並び）
Future<List<String>?> showPlaylistTagsDialog(
  BuildContext context, {
  required List<Tag> tags,
  required Set<String> selected,
  required int Function(Tag tag) countOf,
  LoopItem? Function(Tag tag)? thumbOf,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _PlaylistTagsDialog(
        tags: tags, initial: selected, countOf: countOf, thumbOf: thumbOf),
  );
}

class _PlaylistTagsDialog extends StatefulWidget {
  const _PlaylistTagsDialog({
    required this.tags,
    required this.initial,
    required this.countOf,
    this.thumbOf,
  });

  final List<Tag> tags;
  final Set<String> initial;
  final int Function(Tag tag) countOf;
  final LoopItem? Function(Tag tag)? thumbOf;

  /// 横に 2 列で出す幅（これより狭いか縦長なら上下に分ける）
  static const wideMinWidth = 600.0;

  /// 横に 2 列で出すときのダイアログの幅の上限
  static const wideMaxWidth = 760.0;

  @override
  State<_PlaylistTagsDialog> createState() => _PlaylistTagsDialogState();
}

class _PlaylistTagsDialogState extends State<_PlaylistTagsDialog> {
  late final Set<String> _selected = {...widget.initial};

  void _toggle(Tag tag) {
    setState(() {
      if (!_selected.remove(tag.id)) _selected.add(tag.id);
    });
  }

  static const double _thumbSize = 40;

  /// 行の高さ（チェックの行 1 段。横の 2 列の高さを決めるのに使う）
  static const double _rowHeight = 56;

  /// タグの行: 色の印・サムネ・名前・曲数・チェック
  Widget _row(Tag tag) {
    final textTheme = Theme.of(context).textTheme;
    final thumb = widget.thumbOf?.call(tag);
    return CheckboxListTile(
      key: ValueKey(tag.id),
      value: _selected.contains(tag.id),
      onChanged: (_) => _toggle(tag),
      secondary: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.label, size: AppIconSizes.md, color: tag.color),
          const SizedBox(width: AppSpacing.md),
          ClipRRect(
            borderRadius: AppRadius.borderSm,
            child: SizedBox(
              width: _thumbSize,
              height: _thumbSize,
              child: thumb != null
                  ? ItemThumbnail(item: thumb, iconSize: AppIconSizes.sm)
                  : ColoredBox(color: tag.color.withValues(alpha: 0.15)),
            ),
          ),
        ],
      ),
      // 名前の右に曲数
      title: Row(
        children: [
          Expanded(
            child: Text(tag.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyLarge),
          ),
          const SizedBox(width: AppSpacing.md),
          Text('${widget.countOf(tag)} 曲', style: textTheme.labelSmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = AppTheme.muted(context, alpha: 0.4);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= _PlaylistTagsDialog.wideMinWidth &&
        size.width > size.height;
    final picked = [
      for (final t in widget.tags)
        if (_selected.contains(t.id)) t
    ];
    final others = [
      for (final t in widget.tags)
        if (!_selected.contains(t.id)) t
    ];
    final line = AppTheme.muted(context, alpha: 0.2);

    final Widget content;
    if (widget.tags.isEmpty) {
      content = Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text('タグがありません',
            style: textTheme.bodyMedium?.copyWith(color: dim)),
      );
    } else if (wide) {
      // 横: 左に選んだタグ、右にほかのタグ（間に縦の線）。それぞれの列で縦に流れる
      Widget column(List<Tag> tags) => tags.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text('選択なし',
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(color: dim)),
            )
          : ListView(children: [for (final t in tags) _row(t)]);
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: column(picked)),
          VerticalDivider(width: 1, color: line),
          Expanded(child: column(others)),
        ],
      );
    } else {
      // 縦: 上に選んだタグ、区切りの線、下にほかのタグ（全体で縦に流れる）
      content = ListView(
        shrinkWrap: true,
        children: [
          for (final t in picked) _row(t),
          if (picked.isNotEmpty && others.isNotEmpty)
            Divider(height: 1, color: line),
          for (final t in others) _row(t),
        ],
      );
    }

    final title = Text('タグで自動追加', style: textTheme.displaySmall);
    final actions = [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        // タグ一覧の並びで保存
        onPressed: () => Navigator.pop<List<String>>(context, [
          for (final t in widget.tags)
            if (_selected.contains(t.id)) t.id
        ]),
        child: const Text('OK'),
      ),
    ];

    return AlertDialog(
      // 横（2 列）はボタンを見出しの行の右に置き（幅が広く見出しの右が空いている）、
      // 下のボタンの行の分も一覧に使う。低い画面の入力ダイアログ（AppFormDialog）と同じ形
      title: wide
          ? Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: AppSpacing.md),
                for (final a in actions) ...[
                  const SizedBox(width: AppSpacing.xs),
                  a,
                ],
              ],
            )
          : title,
      titlePadding: wide
          ? const EdgeInsets.fromLTRB(
              AppSpacing.xxl, AppSpacing.md, AppSpacing.lg, 0)
          : null,
      contentPadding: EdgeInsets.only(
          top: AppSpacing.md, bottom: wide ? AppSpacing.lg : AppSpacing.md),
      constraints: wide
          ? const BoxConstraints(
              minWidth: 280, maxWidth: _PlaylistTagsDialog.wideMaxWidth)
          : null,
      content: SizedBox(
        width: double.maxFinite,
        // 横の 2 列は行の多い方に合わせた高さ（入りきらなければダイアログの高さまでで、列の中で流す）
        height: wide && widget.tags.isNotEmpty
            ? max(picked.length, others.length) * _rowHeight + AppSpacing.md
            : null,
        child: content,
      ),
      actions: wide ? null : actions,
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
