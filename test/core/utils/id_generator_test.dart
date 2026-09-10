import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/id_generator.dart';

void main() {
  group('IdGenerator.next', () {
    // 一括追加のように同一ミリ秒で何件も生成する場面があるので、
    // 時刻だけに頼らないことを保証する
    test('連続して大量に生成しても重複しない', () {
      final ids = List.generate(10000, (_) => IdGenerator.next());
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('空文字にならない', () {
      expect(IdGenerator.next(), isNotEmpty);
    });
  });

  group('IdGenerator.child', () {
    test('親IDと種別が前置される', () {
      final id = IdGenerator.child('item1', 'r');
      expect(id, startsWith('item1_r'));
    });

    // 区間IDが個数ベース（_r0, _r1…）だった頃は、削除後に追加すると
    // 既存IDと衝突してプレイリストの区間選択が壊れていた
    test('同じ親に対して連続生成しても重複しない', () {
      final ids = List.generate(1000, (_) => IdGenerator.child('item1', 'r'));
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('親が違えばIDも違う', () {
      expect(IdGenerator.child('a', 'r'), isNot(IdGenerator.child('b', 'r')));
    });
  });
}
