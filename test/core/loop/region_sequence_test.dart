import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/constants.dart';
import 'package:u2b_loop_app/core/loop/region_sequence.dart';
import 'package:u2b_loop_app/models/loop_region.dart';

void main() {
  LoopRegion r(String id, int? a, int? b) =>
      LoopRegion(id: id, name: id, pointAMs: a, pointBMs: b);

  final regions = [
    r('1', 10000, 30000),
    r('未設定', 40000, null),
    r('逆', 45000, 42000),
    r('2', 50000, 70000),
    r('3', 5000, 6000),
  ];

  test('区間は 100 件まで', () => expect(AppLimits.maxRegions, 100));

  test('A < B の区間だけを一覧の順に使う', () {
    expect(RegionSequence.playableIndexes(regions), [0, 3, 4]);
    expect(RegionSequence.ranges(regions),
        [(10000, 30000), (50000, 70000), (5000, 6000)]);
    expect(RegionSequence.totalMs(regions), 41000);
  });

  test('次の区間は使えないものを飛ばし、最後の次は最初', () {
    expect(RegionSequence.nextIndex(regions, 0), 3);
    expect(RegionSequence.nextIndex(regions, 3), 4);
    expect(RegionSequence.nextIndex(regions, 4), 0);
    expect(RegionSequence.nextIndex(regions, -1), 0);
  });

  test('始める区間は今の区間、使えなければ最初', () {
    expect(RegionSequence.startIndex(regions, 3), 3);
    expect(RegionSequence.startIndex(regions, 1), 0);
    expect(RegionSequence.startIndex(regions, -1), 0);
    expect(RegionSequence.startIndex([r('x', 1, null)], 0), isNull);
  });

  test('つなげるのは使える区間が 2 つ以上', () {
    expect(RegionSequence.canJoin(regions), isTrue);
    expect(RegionSequence.canJoin([r('1', 0, 10), r('x', 5, null)]), isFalse);
  });
}
