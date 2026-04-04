import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

/// タグのプリセットカラー
const tagPresetColors = [
  null, // デフォルト（テーマカラー）
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

  Tag({required this.id, required this.name, this.colorIndex = 0});

  Color? get color =>
      colorIndex > 0 && colorIndex < tagPresetColors.length
          ? tagPresetColors[colorIndex]
          : null;
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
    );
  }

  @override
  void write(BinaryWriter writer, Tag obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.name,
      2: obj.colorIndex,
    });
  }
}
