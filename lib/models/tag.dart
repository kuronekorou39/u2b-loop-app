import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../core/theme/app_theme.dart';
import 'loop_item.dart';

/// タグのプリセットカラー（index 0 = デフォルト青緑）
const tagPresetColors = [
  AppTheme.accentGreen, // デフォルト（アクセントグリーン）
  Color(0xFFEF5350), // 赤
  Color(0xFFFF7043), // オレンジ
  Color(0xFFFFCA28), // 黄
  Color(0xFF66BB6A), // 緑
  Color(0xFF42A5F5), // 青
  Color(0xFFAB47BC), // 紫
  Color(0xFF78909C), // グレー
];

class Tag {
  String id;
  String name;
  int colorIndex;

  /// 並び順（小さいほど上）。タグ一覧でユーザーが並べ替える。曲に付いたタグもこの順に出す。
  /// null = まだ決まっていない（v1.101.1 までのタグ。読み込むときに名前順で振る）
  int? order;

  /// タグ一覧に出すサムネの曲（ユーザーが選んだもの）。null = 自動（[thumbItemOf]）
  String? thumbItemId;

  /// サムネにする曲: 選んだ曲（まだこのタグが付いていてサムネがあれば）、
  /// 無ければこのタグの曲でサムネのあるもののうち一番よく再生した曲（同じなら新しい方）
  LoopItem? thumbItemOf(Iterable<LoopItem> items) {
    LoopItem? best;
    for (final item in items) {
      if (!item.tagIds.contains(id) || item.thumbnailPath == null) continue;
      if (item.id == thumbItemId) return item;
      if (best == null ||
          item.playCount > best.playCount ||
          (item.playCount == best.playCount && item.createdAt.isAfter(best.createdAt))) {
        best = item;
      }
    }
    return best;
  }

  Tag({
    required this.id,
    required this.name,
    this.colorIndex = 0,
    this.order,
    this.thumbItemId,
  });

  /// 一覧の並び: 並び順、決まっていなければ後ろに名前順
  static int compare(Tag a, Tag b) {
    final ao = a.order, bo = b.order;
    if (ao != null && bo != null && ao != bo) return ao.compareTo(bo);
    if (ao != null && bo == null) return -1;
    if (ao == null && bo != null) return 1;
    return a.name.compareTo(b.name);
  }

  Color get color =>
      colorIndex >= 0 && colorIndex < tagPresetColors.length
          ? tagPresetColors[colorIndex]
          : tagPresetColors[0];
}

class TagAdapter extends TypeAdapter<Tag> {
  @override
  final int typeId = 2;

  @override
  Tag read(BinaryReader reader) {
    final fields = reader.readMap().cast<int, dynamic>();
    return Tag(
      id: fields[0] as String,
      name: fields[1] as String,
      colorIndex: fields[2] as int? ?? 0,
      order: fields[3] as int?,
      thumbItemId: fields[4] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Tag obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.name,
      2: obj.colorIndex,
      3: obj.order,
      4: obj.thumbItemId,
    });
  }
}
