import 'package:hive/hive.dart';

import 'loop_item.dart';

class Playlist {
  String id;
  String name;
  List<String> itemIds;
  DateTime createdAt;

  /// アイテムごとの区間選択: itemId → 選択されたregionIdリスト
  /// マップに存在しない → 全区間を含める（後方互換）
  /// 空リスト → 0区間選択（そのアイテムはスキップ）
  Map<String, List<String>> regionSelections;

  /// 無効化されたアイテムのIDセット（再生時にスキップ）
  Set<String> disabledItemIds;

  /// サムネイル用のアイテムID（nullなら最初のアイテムを使用）
  String? thumbnailItemId;

  /// デフォルトでシャッフルON
  bool defaultShuffle;

  /// 自動で入れるタグ（どれか 1 つが付いた曲を入れる = OR）。
  /// 後からタグを付けた曲も入り、タグを外した曲は抜ける（[syncTagItems]）
  List<String> tagIds;

  /// タグで入った曲（手で足した曲は含まない）。タグが外れたらプレイリストから抜く対象
  Set<String> tagItemIds;

  /// タグに当てはまるが、ユーザーが外した曲（もう自動では入れない）
  Set<String> excludedItemIds;

  Playlist({
    required this.id,
    required this.name,
    List<String>? itemIds,
    DateTime? createdAt,
    Map<String, List<String>>? regionSelections,
    Set<String>? disabledItemIds,
    this.thumbnailItemId,
    this.defaultShuffle = false,
    List<String>? tagIds,
    Set<String>? tagItemIds,
    Set<String>? excludedItemIds,
  })  : itemIds = itemIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        regionSelections = regionSelections ?? {},
        disabledItemIds = disabledItemIds ?? {},
        tagIds = tagIds ?? [],
        tagItemIds = tagItemIds ?? {},
        excludedItemIds = excludedItemIds ?? {};

  /// [item] が自動で入れるタグに当てはまるか
  bool matchesTags(LoopItem item) =>
      item.isReady && item.tagIds.any(tagIds.contains);

  /// 自動で入れるタグに合わせて中身を直す。変わったら true。
  /// - 当てはまる曲で、まだ入っておらず外されてもいない曲を末尾に足す（[items] の並び順）
  /// - タグで入った曲のうち、もう当てはまらない曲を抜く（手で足した曲は残す）
  bool syncTagItems(Iterable<LoopItem> items) {
    if (tagIds.isEmpty && tagItemIds.isEmpty && excludedItemIds.isEmpty) {
      return false;
    }
    final matched = [for (final i in items) if (matchesTags(i)) i.id];
    final matchedSet = matched.toSet();
    var changed = false;
    for (final id in tagItemIds.where((id) => !matchedSet.contains(id)).toList()) {
      tagItemIds.remove(id);
      itemIds.remove(id);
      regionSelections.remove(id);
      disabledItemIds.remove(id);
      if (thumbnailItemId == id) thumbnailItemId = null;
      changed = true;
    }
    final before = excludedItemIds.length;
    excludedItemIds.removeWhere((id) => !matchedSet.contains(id));
    if (excludedItemIds.length != before) changed = true;
    for (final id in matched) {
      if (itemIds.contains(id) || excludedItemIds.contains(id)) continue;
      itemIds.add(id);
      tagItemIds.add(id);
      changed = true;
    }
    return changed;
  }

  /// サムネに使うアイテムIDを返す（明示設定 or 最初のアイテム）
  String? get effectiveThumbnailItemId =>
      thumbnailItemId ?? (itemIds.isNotEmpty ? itemIds.first : null);
}

class PlaylistAdapter extends TypeAdapter<Playlist> {
  @override
  final int typeId = 1;

  @override
  Playlist read(BinaryReader reader) {
    final fields = reader.readMap().cast<int, dynamic>();

    // field 4: regionSelections (後方互換: 旧データにはない)
    Map<String, List<String>>? regionSel;
    if (fields.containsKey(4) && fields[4] != null) {
      final raw = (fields[4] as Map).cast<String, dynamic>();
      regionSel = raw.map((k, v) => MapEntry(k, (v as List).cast<String>()));
    }

    // field 5: disabledItemIds (後方互換: 旧データにはない)
    Set<String>? disabled;
    if (fields.containsKey(5) && fields[5] != null) {
      disabled = (fields[5] as List).cast<String>().toSet();
    }

    // field 6: thumbnailItemId (後方互換: 旧データにはない)
    final thumbnailItemId = fields[6] as String?;

    return Playlist(
      id: fields[0] as String,
      name: fields[1] as String,
      itemIds: (fields[2] as List?)?.cast<String>() ?? [],
      createdAt: DateTime.fromMillisecondsSinceEpoch(fields[3] as int),
      regionSelections: regionSel,
      disabledItemIds: disabled,
      thumbnailItemId: thumbnailItemId,
      defaultShuffle: fields[7] as bool? ?? false,
      tagIds: (fields[8] as List?)?.cast<String>(),
      tagItemIds: (fields[9] as List?)?.cast<String>().toSet(),
      excludedItemIds: (fields[10] as List?)?.cast<String>().toSet(),
    );
  }

  @override
  void write(BinaryWriter writer, Playlist obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.name,
      2: obj.itemIds,
      3: obj.createdAt.millisecondsSinceEpoch,
      4: obj.regionSelections.isNotEmpty ? obj.regionSelections : null,
      5: obj.disabledItemIds.isNotEmpty ? obj.disabledItemIds.toList() : null,
      6: obj.thumbnailItemId,
      7: obj.defaultShuffle ? true : null,
      8: obj.tagIds.isNotEmpty ? obj.tagIds : null,
      9: obj.tagItemIds.isNotEmpty ? obj.tagItemIds.toList() : null,
      10: obj.excludedItemIds.isNotEmpty ? obj.excludedItemIds.toList() : null,
    });
  }
}
