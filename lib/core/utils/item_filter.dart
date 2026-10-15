import '../../models/loop_item.dart';

/// ホームの曲一覧の並び順
enum ItemSortMode {
  updatedDesc('更新日（新→古）'),
  updatedAsc('更新日（古→新）'),
  createdDesc('作成日（新→古）'),
  titleAsc('タイトル（A→Z）'),
  titleDesc('タイトル（Z→A）'),
  playCountDesc('再生回数（多→少）');

  const ItemSortMode(this.label);
  final String label;
}

/// ホームの曲一覧の絞り込みと並び替え（画面から切り出した純粋関数）。
///
/// タグの絞り込みは 3 状態: `true` = 含む（指定したタグを**すべて**持つ）、
/// `false` = 除外（1 つでも持っていれば外す）、無指定 = 見ない。
/// [untaggedId] はタグの無い曲を指す特別なキー。
class ItemFilter {
  ItemFilter._();

  static const untaggedId = '__untagged__';

  static List<LoopItem> byTags(List<LoopItem> items, Map<String, bool> filter) {
    if (filter.isEmpty) return items;
    final include = {
      for (final e in filter.entries)
        if (e.value && e.key != untaggedId) e.key,
    };
    final exclude = {
      for (final e in filter.entries)
        if (!e.value && e.key != untaggedId) e.key,
    };
    final includeUntagged = filter[untaggedId] == true;
    final excludeUntagged = filter[untaggedId] == false;
    return items.where((i) {
      // 除外（1 つでも該当すれば外す）
      if (excludeUntagged && i.tagIds.isEmpty) return false;
      if (exclude.any(i.tagIds.contains)) return false;
      // 包含
      if (include.isEmpty && !includeUntagged) return true;
      if (includeUntagged && i.tagIds.isEmpty) return true;
      if (include.isNotEmpty) return include.every(i.tagIds.contains);
      return false;
    }).toList();
  }

  /// 曲名とメモの部分一致（大文字小文字は区別しない）
  static List<LoopItem> bySearch(List<LoopItem> items, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items
        .where((i) =>
            i.title.toLowerCase().contains(q) ||
            (i.memo ?? '').toLowerCase().contains(q))
        .toList();
  }

  static List<LoopItem> sorted(List<LoopItem> items, ItemSortMode mode) {
    final out = List<LoopItem>.from(items);
    switch (mode) {
      case ItemSortMode.updatedDesc:
        out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case ItemSortMode.updatedAsc:
        out.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      case ItemSortMode.titleAsc:
        out.sort((a, b) => a.title.compareTo(b.title));
      case ItemSortMode.titleDesc:
        out.sort((a, b) => b.title.compareTo(a.title));
      case ItemSortMode.createdDesc:
        out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case ItemSortMode.playCountDesc:
        out.sort((a, b) => b.playCount.compareTo(a.playCount));
    }
    return out;
  }

  /// タグ → 検索 → 並び替え の順に適用
  static List<LoopItem> apply(
    List<LoopItem> items, {
    Map<String, bool> tagFilter = const {},
    String query = '',
    ItemSortMode sort = ItemSortMode.updatedDesc,
  }) =>
      sorted(bySearch(byTags(items, tagFilter), query), sort);
}
