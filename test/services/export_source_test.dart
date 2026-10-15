import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/export_source.dart';

void main() {
  group('ExportSource.pickHeight', () {
    test('希望以下で最大のものを選ぶ', () {
      expect(ExportSource.pickHeight([1080, 720, 480, 360], 720), 720);
      expect(ExportSource.pickHeight([1080, 720, 480, 360], 1080), 1080);
      // 1080 が無ければ 720 に落とす
      expect(ExportSource.pickHeight([720, 480, 360], 1080), 720);
    });

    test('希望より大きいものしか無ければ一番小さいもの', () {
      expect(ExportSource.pickHeight([1080, 720], 480), 720);
    });

    test('候補が無ければ null', () {
      expect(ExportSource.pickHeight([], 720), isNull);
    });
  });

  test('ExportQuality.fromName は不明なら 720p、360p だけ結合不要', () {
    expect(ExportQuality.fromName('p1080'), ExportQuality.p1080);
    expect(ExportQuality.fromName(null), ExportQuality.p720);
    expect(ExportQuality.fromName('x'), ExportQuality.p720);
    expect(ExportQuality.p360.needsMerge, isFalse);
    expect(ExportQuality.p720.needsMerge, isTrue);
  });
}
