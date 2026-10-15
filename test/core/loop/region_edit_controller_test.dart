import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/loop/region_edit_controller.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';

/// 区間一覧の編集ルール（再生画面と AB 設定画面で共通）
void main() {
  LoopRegion r(String name, {int? a, int? b}) =>
      LoopRegion(id: name, name: name, pointAMs: a, pointBMs: b);

  group('追加', () {
    test('「区間 N」で今の位置を A にして末尾に足し、それを選ぶ', () {
      final c = RegionEditController(regions: [r('x')], selected: 0);
      final added = c.add(positionMs: 1500)!;
      expect(added.name, '区間 2');
      expect(added.pointAMs, 1500);
      expect(added.pointBMs, isNull);
      expect(c.regions.length, 2);
      expect(c.selected, 1);
      expect(c.current, same(added));
    });

    test('上限では足さず null', () {
      final c = RegionEditController(
          regions: [r('1'), r('2')], selected: 0, maxRegions: 2);
      expect(c.canAdd, isFalse);
      expect(c.add(positionMs: 0), isNull);
      expect(c.regions.length, 2);
    });
  });

  group('削除', () {
    test('最後の 1 つも消せて、選択は「全体」（-1）になる', () {
      final c = RegionEditController(regions: [r('only')], selected: 0);
      expect(c.delete(0), isTrue);
      expect(c.regions, isEmpty);
      expect(c.selected, -1);
      expect(c.current, isNull);
    });

    test('選択中を消すと同じ位置（次の区間）、末尾なら 1 つ前', () {
      final c = RegionEditController(
          regions: [r('a'), r('b'), r('c')], selected: 1);
      c.delete(1);
      expect(c.current!.name, 'c');
      expect(c.selected, 1);
      c.delete(1);
      expect(c.current!.name, 'a');
      expect(c.selected, 0);
    });

    test('選択より前を消しても選択はずれない（以前は別の区間に飛んでいた）', () {
      final c = RegionEditController(
          regions: [r('a'), r('b'), r('c')], selected: 2);
      c.delete(0);
      expect(c.current!.name, 'c');
      expect(c.selected, 1);
    });

    test('「全体」を選んでいるときに消しても -1 のまま', () {
      final c = RegionEditController(regions: [r('a'), r('b')], selected: -1);
      c.delete(0);
      expect(c.selected, -1);
    });

    test('範囲外は何もしない', () {
      final c = RegionEditController(regions: [r('a')], selected: 0);
      expect(c.delete(3), isFalse);
      expect(c.regions.length, 1);
    });
  });

  group('名前・選択・同期', () {
    test('rename は名前だけ変えて A/B は据え置く', () {
      final c = RegionEditController(
          regions: [r('a', a: 10, b: 20)], selected: 0);
      c.rename(0, 'サビ');
      expect(c.regions[0].name, 'サビ');
      expect(c.regions[0].pointAMs, 10);
      expect(c.regions[0].pointBMs, 20);
    });

    test('select は -1（全体）〜末尾だけ受ける', () {
      final c = RegionEditController(regions: [r('a'), r('b')], selected: 0);
      expect(c.select(1), isTrue);
      expect(c.select(-1), isTrue);
      expect(c.select(2), isFalse);
      expect(c.selected, -1);
    });

    test('syncFromLoop は選択中の区間へ A/B を写し、null で消す', () {
      final c = RegionEditController(
          regions: [r('a', a: 1, b: 2), r('b', a: 3, b: 4)], selected: 1);
      c.syncFromLoop(const Duration(seconds: 5), null);
      expect(c.regions[1].pointAMs, 5000);
      expect(c.regions[1].pointBMs, isNull);
      expect(c.regions[0].pointAMs, 1, reason: '他の区間は触らない');
      c.select(-1);
      c.syncFromLoop(const Duration(seconds: 9), null);
      expect(c.regions[1].pointAMs, 5000, reason: '全体のときは何もしない');
    });
  });

  group('differs', () {
    test('件数・名前・A・B のどれかが違えば true', () {
      final base = [r('a', a: 1, b: 2)];
      expect(RegionEditController.differs(base, [r('a', a: 1, b: 2)]), isFalse);
      expect(RegionEditController.differs(base, []), isTrue);
      expect(RegionEditController.differs(base, [r('b', a: 1, b: 2)]), isTrue);
      expect(RegionEditController.differs(base, [r('a', a: 9, b: 2)]), isTrue);
      expect(RegionEditController.differs(base, [r('a', a: 1, b: null)]), isTrue);
    });
  });

  group('LoopItem.setRegions', () {
    test('先頭の区間を旧 AB 値にも写す。区間なしなら 0 に戻す', () {
      final item = LoopItem(
          id: 'i', title: 't', uri: 'u', sourceType: 'local',
          pointAMs: 100, pointBMs: 200);
      item.setRegions([r('a', a: 300, b: 400), r('b', a: 1, b: 2)]);
      expect(item.regions.length, 2);
      expect(item.pointAMs, 300);
      expect(item.pointBMs, 400);

      item.setRegions([]);
      expect(item.regions, isEmpty);
      expect(item.pointAMs, 0);
      expect(item.pointBMs, 0);
      expect(item.effectiveRegions, isEmpty,
          reason: '旧値が残っていると消した区間が蘇る');
    });

    test('渡したリストとは別のリストを持つ（呼び元で消しても影響しない）', () {
      final item = LoopItem(id: 'i', title: 't', uri: 'u', sourceType: 'local');
      final list = [r('a')];
      item.setRegions(list);
      list.clear();
      expect(item.regions.length, 1);
    });
  });
}
