import 'package:hive/hive.dart';

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

  Playlist({
    required this.id,
    required this.name,
    List<String>? itemIds,
    DateTime? createdAt,
    Map<String, List<String>>? regionSelections,
    Set<String>? disabledItemIds,
    this.thumbnailItemId,
  })  : itemIds = itemIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        regionSelections = regionSelections ?? {},
        disabledItemIds = disabledItemIds ?? {};

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
    });
  }
}
