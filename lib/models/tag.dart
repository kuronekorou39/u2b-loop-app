import 'package:hive/hive.dart';

class Tag {
  String id;
  String name;

  Tag({required this.id, required this.name});
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
    );
  }

  @override
  void write(BinaryWriter writer, Tag obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.name,
    });
  }
}
