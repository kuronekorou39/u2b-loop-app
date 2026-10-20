import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';

/// タグの並び: ユーザーが決めた順。決まっていないタグは名前順で後ろ、読み込み時に番号を振る
void main() {
  test('Tag.compare: 並び順が先、無ければ後ろに名前順', () {
    final list = [
      Tag(id: '1', name: 'b'),
      Tag(id: '2', name: 'z', order: 1),
      Tag(id: '3', name: 'a'),
      Tag(id: '4', name: 'y', order: 0),
    ]..sort(Tag.compare);
    expect(list.map((t) => t.name), ['y', 'z', 'a', 'b']);
  });

  group('TagsNotifier', () {
    late Box<Tag> box;

    setUpAll(() {
      Hive.init(null);
      if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(TagAdapter());
    });

    setUp(() async {
      box = await Hive.openBox<Tag>('tags_test', bytes: Uint8List(0));
    });

    tearDown(() async {
      await box.clear();
      await box.close();
    });

    test('並び順の無いタグには名前順で番号を振る', () async {
      await box.putAll({
        'c': Tag(id: 'c', name: 'ccc'),
        'a': Tag(id: 'a', name: 'aaa'),
        'b': Tag(id: 'b', name: 'bbb'),
      });
      final n = TagsNotifier(box);
      expect(n.state.map((t) => t.name), ['aaa', 'bbb', 'ccc']);
      expect(box.get('c')!.order, 2);
    });

    test('並べ替えると保存され、新しいタグは末尾に入る', () async {
      await box.putAll({
        'a': Tag(id: 'a', name: 'aaa', order: 0),
        'b': Tag(id: 'b', name: 'bbb', order: 1),
        'c': Tag(id: 'c', name: 'ccc', order: 2),
      });
      final n = TagsNotifier(box);
      n.reorder(2, 0); // ccc を先頭へ
      expect(n.state.map((t) => t.name), ['ccc', 'aaa', 'bbb']);
      n.reorder(0, 2); // ccc を末尾へ
      expect(n.state.map((t) => t.name), ['aaa', 'bbb', 'ccc']);
      await n.create('aaa0');
      expect(n.state.last.name, 'aaa0');
      expect(TagsNotifier(box).state.map((t) => t.name),
          ['aaa', 'bbb', 'ccc', 'aaa0']);
    });
  });
}
