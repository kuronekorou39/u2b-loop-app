import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../models/loop_item.dart';
import '../../models/tag.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/item_thumbnail.dart';
import '../../widgets/tag_chip.dart';
import 'home_parts.dart';

/// 曲一覧の表示モード: リスト / 2列 / 4列
enum ItemViewMode {
  list(Icons.view_list, '2列表示へ'),
  grid2(Icons.grid_view, '4列表示へ'),
  grid4(Icons.apps, 'リスト表示へ');

  const ItemViewMode(this.icon, this.nextTooltip);

  /// AppBar のボタンに出すアイコン（いまのモード）
  final IconData icon;

  /// 押すと次のモードへ。その説明
  final String nextTooltip;

  ItemViewMode get next => switch (this) {
        ItemViewMode.list => ItemViewMode.grid2,
        ItemViewMode.grid2 => ItemViewMode.grid4,
        ItemViewMode.grid4 => ItemViewMode.list,
      };
}

/// ホームの曲一覧（リスト / グリッド）。選択状態と操作はコールバックで親（ListScreen）へ
class ItemCollectionView extends StatelessWidget {
  const ItemCollectionView({
    super.key,
    required this.items,
    required this.tags,
    required this.viewMode,
    required this.selectedIds,
    required this.selecting,
    required this.onOpen,
    required this.onLongPress,
    required this.onToggleSelect,
    required this.onDelete,
    required this.onRetry,
  });

  final List<LoopItem> items;
  final List<Tag> tags;
  final ItemViewMode viewMode;
  final Set<String> selectedIds;

  /// 複数選択中（チェックの枠を出す）
  final bool selecting;
  final ValueChanged<LoopItem> onOpen;
  final ValueChanged<LoopItem> onLongPress;
  final ValueChanged<LoopItem> onToggleSelect;
  final ValueChanged<LoopItem> onDelete;
  final ValueChanged<LoopItem> onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (viewMode) {
      ItemViewMode.list => _buildList(context),
      // サムネ + 曲名 + 情報 + タグが収まる高さ（ガラス面の余白ぶん縦長）
      ItemViewMode.grid2 =>
        _buildGrid(context, maxExtent: 220, ratio: 16 / 15.5, compact: false),
      ItemViewMode.grid4 =>
        _buildGrid(context, maxExtent: 120, ratio: 16 / 11, compact: true),
    };
  }

  // === Grid ===

  Widget _buildGrid(BuildContext context,
      {required double maxExtent, required double ratio, required bool compact}) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    // 幅に応じて列数を自動算出（横画面・タブレットで列が増える）
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: ratio,
        crossAxisSpacing: compact ? AppSpacing.sm : AppSpacing.md + 2,
        mainAxisSpacing: compact ? AppSpacing.sm : AppSpacing.md + 2,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildCard(context, items[i], compact: compact),
    );
  }

  /// グリッドのカード（ガラス面）。サムネ・曲名・区間/メモ・タグ。
  /// 選択中は緑の薄い面 + チェック
  Widget _buildCard(BuildContext context, LoopItem item,
      {required bool compact}) {
    final selected = selectedIds.contains(item.id);
    final pad = compact ? 3.0 : AppSpacing.md;
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 6 : 10),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ItemThumbnail(
                item: item,
                heroTag: 'thumb_${item.id}',
                iconSize: compact ? AppIconSizes.s : null),
            // 字幕バッジ
            if (item.hasSubtitles == true)
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: AppRadius.borderXs,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.subtitles, size: 12, color: Colors.white70),
                      SizedBox(width: 2),
                      Text('CC',
                          style: TextStyle(fontSize: 11, color: Colors.white70)),
                    ],
                  ),
                ),
              ),
            // オフライン保存バッジ
            if (item.isCached)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentGreen.withValues(alpha: 0.9),
                    borderRadius: AppRadius.borderSm,
                  ),
                  child: const Icon(Icons.offline_pin,
                      size: 11, color: AppTheme.darkBackground),
                ),
              ),
            if (item.isFetching || item.hasError) _StatusOverlay(item: item),
            if (selected)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.check,
                      size: AppIconSizes.xs, color: AppTheme.darkBackground),
                ),
              ),
            if (selecting && !selected)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white70, width: 2),
                  ),
                  width: 20,
                  height: 20,
                ),
              ),
          ],
        ),
      ),
    );

    return GlassSurface(
      radius: compact ? 10 : 16,
      padding: EdgeInsets.all(pad),
      tint: selected ? AppTheme.accentGreen.withValues(alpha: 0.15) : null,
      onTap: () => onOpen(item),
      onLongPress: () => onLongPress(item),
      child: compact
          ? thumb
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                thumb,
                const SizedBox(height: AppSpacing.sm),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (item.isReady)
                  if (cardInfoText(item) case final info?)
                    Text(
                      info,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                if (item.tagIds.isNotEmpty) ...[
                  const Spacer(),
                  _tagChips(item, tiny: true),
                ],
              ],
            ),
    );
  }

  /// カードの 2 行目: BPM・キー・区間数（無ければメモ）
  static String? cardInfoText(LoopItem item) {
    final withPoints = item.effectiveRegions.where((r) => r.hasPoints).length;
    final parts = <String>[
      ...item.musicInfoParts,
      if (withPoints > 0) '区間 $withPoints',
    ];
    if (parts.isNotEmpty) return parts.join('  ·  ');
    if (item.memo != null && item.memo!.isNotEmpty) return item.memo;
    return null;
  }

  Widget _tagChips(LoopItem item, {bool tiny = false}) {
    final itemTags = tags.where((t) => item.tagIds.contains(t.id)).toList();
    if (itemTags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: 2,
      children: [for (final t in itemTags) TagChip(tag: t, small: tiny)],
    );
  }

  // === List ===

  Widget _buildList(BuildContext context) {
    return HomeListSurface(
      child: ListView.builder(
        padding: HomeListSurface.listPadding,
        itemCount: items.length,
        itemBuilder: (context, i) => _buildTile(context, items[i]),
      ),
    );
  }

  Widget _buildTile(BuildContext context, LoopItem item) {
    final textTheme = Theme.of(context).textTheme;
    final selected = selectedIds.contains(item.id);
    return ListTile(
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selecting)
            Checkbox(
              value: selected,
              onChanged: (_) => onToggleSelect(item),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ClipRRect(
            borderRadius: AppRadius.borderXs,
            child: SizedBox(
              width: 64,
              height: 36,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ItemThumbnail(item: item, heroTag: 'thumb_${item.id}'),
                  if (item.isFetching)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: SizedBox(
                          width: AppIconSizes.s,
                          height: AppIconSizes.s,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    ),
                  if (item.hasError)
                    Container(
                      color: Colors.black54,
                      child: const Icon(Icons.error_outline,
                          size: AppIconSizes.sm, color: Colors.orange),
                    ),
                  if (item.hasSubtitles == true)
                    const Positioned(
                      left: 2,
                      bottom: 2,
                      child: Icon(Icons.subtitles,
                          size: 10, color: Colors.white70),
                    ),
                  if (item.isCached)
                    const Positioned(
                      right: 2,
                      bottom: 2,
                      child: Icon(Icons.offline_pin,
                          size: 11, color: AppTheme.accentGreen),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      title: Text(
        item.isFetching ? 'データ取得中...' : item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: item.isFetching
            ? textTheme.bodyLarge?.copyWith(color: AppTheme.muted(context))
            : textTheme.bodyLarge,
      ),
      subtitle: _buildSubtitle(context, item),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              tooltip: 'メニュー',
              onSelected: (v) {
                if (v == 'delete') onDelete(item);
                if (v == 'retry') onRetry(item);
              },
              itemBuilder: (_) => [
                if (item.hasError)
                  const PopupMenuItem(value: 'retry', child: Text('再試行')),
                const PopupMenuItem(value: 'delete', child: Text('削除')),
              ],
            ),
      onTap: () => onOpen(item),
      onLongPress: () => onLongPress(item),
    );
  }

  /// リストの 2 行目: 先頭区間の A–B・速度・再生回数・BPM/キー・メモ
  static String? regionInfoText(LoopItem item) {
    final regions = item.effectiveRegions;
    final first = regions.firstOrNull;
    if (first == null || !first.hasPoints) return null;

    final parts = <String>[];
    if (first.name != '区間 1' && regions.length > 1) parts.add(first.name);
    parts.add(
        'A ${TimeUtils.formatShortMs(first.pointAMs)} - B ${TimeUtils.formatShortMs(first.pointBMs)}');
    if (regions.length > 1) parts.add('他${regions.length - 1}件');
    return parts.join('  ');
  }

  Widget? _buildSubtitle(BuildContext context, LoopItem item) {
    final textTheme = Theme.of(context).textTheme;
    if (item.isFetching) {
      return Text('情報を取得中...',
          style: textTheme.labelSmall?.copyWith(color: AppTheme.muted(context)));
    }
    if (item.hasError) {
      return Text('取得失敗（タップで操作）',
          style: textTheme.labelSmall?.copyWith(color: Colors.orange.shade300));
    }

    final info = <String>[
      ?regionInfoText(item),
      if (item.speed != 1.0) '${item.speed}x',
      if (item.playCount > 0) '${item.playCount}回',
      ...item.musicInfoParts,
      if (item.memo != null && item.memo!.isNotEmpty) item.memo!,
    ];
    final parts = <Widget>[
      if (info.isNotEmpty)
        Text(info.join('  |  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                textTheme.labelSmall?.copyWith(color: AppTheme.muted(context))),
      if (item.tagIds.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _tagChips(item),
        ),
    ];
    if (parts.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: parts,
    );
  }
}

/// サムネの上に被せる「取得中」「取得失敗」
class _StatusOverlay extends StatelessWidget {
  const _StatusOverlay({required this.item});

  final LoopItem item;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: item.isFetching
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: AppIconSizes.lg,
                    height: AppIconSizes.lg,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text('取得中...',
                      style: textTheme.labelSmall?.copyWith(color: Colors.white)),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.orange, size: AppIconSizes.xl),
                  const SizedBox(height: AppSpacing.xs),
                  Text('取得失敗',
                      style: textTheme.labelSmall
                          ?.copyWith(color: Colors.orange.shade300)),
                ],
              ),
      ),
    );
  }
}
