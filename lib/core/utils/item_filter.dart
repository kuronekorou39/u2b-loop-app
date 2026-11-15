import '../../models/loop_item.dart';

/// ホームの曲一覧を並べる項目（昇順・降順は別に選ぶ）
enum ItemSortField {
  updated('更新日'),
  created('作成日'),
  title('タイトル'),
  playCount('再生回数');

  const ItemSortField(this.label);
  final String label;
}

/// ホームの曲一覧の絞り込みと並び替え（画面から切り出した純粋関数）。
///
/// タグの絞り込みは 3 状態: `true` = 含む、`false` = 除外、無指定 = 見ない。
/// 含むは OR（指定したタグを**どれか 1 つ**でも持てば出す。タグを足すほど曲が増える）、
/// 除外は AND（除外したタグを**どれも**持たない曲だけ = 1 つでも持っていれば外す）。
/// 両方あるときは除外が勝つ。
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
      // 含む（どれか 1 つ）
      if (include.isEmpty && !includeUntagged) return true;
      if (includeUntagged && i.tagIds.isEmpty) return true;
      return include.any(i.tagIds.contains);
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

  /// [descending] = 降順（新しい順・多い順・Z→A）
  static List<LoopItem> sorted(List<LoopItem> items, ItemSortField field,
      {bool descending = true}) {
    final int Function(LoopItem, LoopItem) ascending = switch (field) {
      ItemSortField.updated => (a, b) => a.updatedAt.compareTo(b.updatedAt),
      ItemSortField.created => (a, b) => a.createdAt.compareTo(b.createdAt),
      ItemSortField.title => (a, b) => a.title.compareTo(b.title),
      ItemSortField.playCount => (a, b) => a.playCount.compareTo(b.playCount),
    };
    return List<LoopItem>.from(items)
      ..sort(descending ? (a, b) => ascending(b, a) : ascending);
  }

  /// タグ → 検索 → 並び替え の順に適用
  static List<LoopItem> apply(
    List<LoopItem> items, {
    Map<String, bool> tagFilter = const {},
    String query = '',
    ItemSortField sort = ItemSortField.updated,
    bool descending = true,
  }) =>
      sorted(bySearch(byTags(items, tagFilter), query), sort,
          descending: descending);
}
