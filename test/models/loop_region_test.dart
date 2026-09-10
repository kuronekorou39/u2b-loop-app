import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_region.dart';

void main() {
  group('地点の有無', () {
    test('hasA / hasB / hasPoints', () {
      expect(LoopRegion(id: 'r', name: 'n').hasPoints, isFalse);
      expect(LoopRegion(id: 'r', name: 'n', pointAMs: 0).hasA, isTrue,
          reason: '0ミリ秒も「設定済み」として扱う');
      expect(LoopRegion(id: 'r', name: 'n', pointBMs: 100).hasPoints, isTrue);
    });
  });

  group('copyWith', () {
    test('指定しない項目は据え置く', () {
      final r = LoopRegion(id: 'r', name: '元', pointAMs: 100, pointBMs: 200);
      final copy = r.copyWith(name: '新');
      expect(copy.id, 'r');
      expect(copy.name, '新');
      expect(copy.pointAMs, 100);
      expect(copy.pointBMs, 200);
    });

    // 関数で包むのは「nullを渡して消す」と「指定しない」を区別するため
    test('関数で null を渡すと地点を消せる', () {
      final r = LoopRegion(id: 'r', name: 'n', pointAMs: 100, pointBMs: 200);
      final cleared = r.copyWith(pointAMs: () => null);
      expect(cleared.pointAMs, isNull);
      expect(cleared.pointBMs, 200);
    });

    test('元のインスタンスは変更されない', () {
      final r = LoopRegion(id: 'r', name: '元', pointAMs: 100);
      r.copyWith(name: '新', pointAMs: () => 999);
      expect(r.name, '元');
      expect(r.pointAMs, 100);
    });
  });

  group('Map との往復', () {
    test('全項目が保たれる', () {
      final r = LoopRegion(id: 'r1', name: 'サビ', pointAMs: 45000, pointBMs: 78000);
      final back = LoopRegion.fromMap(r.toMap());
      expect(back.id, r.id);
      expect(back.name, r.name);
      expect(back.pointAMs, r.pointAMs);
      expect(back.pointBMs, r.pointBMs);
    });

    test('地点が null でも往復できる', () {
      final r = LoopRegion(id: 'r1', name: '未設定');
      final back = LoopRegion.fromMap(r.toMap());
      expect(back.pointAMs, isNull);
      expect(back.pointBMs, isNull);
    });
  });
}
