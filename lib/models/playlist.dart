import 'package:hive/hive.dart';

class Playlist {
  String id;
  String name;
  List<String> itemIds;
  DateTime createdAt;

  Playlist({
    required this.id,
    required this.name,
    List<String>? itemIds,
    DateTime? createdAt,
  })  : itemIds = itemIds ?? [],
        createdAt = createdAt ?? DateTime.now();
}

class PlaylistAdapter extends TypeAdapter<Playlist> {
  @override
  final int typeId = 1;

  @override
  Playlist read(BinaryReader reader) {
    final fields = reader.readMap().cast<int, dynamic>();
    return Playlist(
      id: fields[0] as String,
      name: fields[1] as String,
      itemIds: (fields[2] as List?)?.cast<String>() ?? [],
      createdAt: DateTime.fromMillisecondsSinceEpoch(fields[3] as int),
    );
  }

  @override
  void write(BinaryWriter writer, Playlist obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.name,
      2: obj.itemIds,
      3: obj.createdAt.millisecondsSinceEpoch,
    });
  }
}
