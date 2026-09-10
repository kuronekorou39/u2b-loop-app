import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/time_utils.dart';

void main() {
  group('TimeUtils.format', () {
    test('M:SS.mmm 形式で0埋めする', () {
      expect(TimeUtils.format(const Duration(minutes: 1, seconds: 2, milliseconds: 3)),
          '1:02.003');
      expect(TimeUtils.format(Duration.zero), '0:00.000');
      expect(TimeUtils.format(const Duration(minutes: 10)), '10:00.000');
    });

    test('負の値は0として扱う（表示が壊れないこと）', () {
      expect(TimeUtils.format(const Duration(seconds: -5)), '0:00.000');
    });

    test('60分を超えても分に繰り上げる（時間表記にしない）', () {
      expect(TimeUtils.format(const Duration(hours: 1, minutes: 5)), '65:00.000');
    });
  });

  group('TimeUtils.formatShort', () {
    test('M:SS 形式でミリ秒を切り捨てる', () {
      expect(TimeUtils.formatShort(const Duration(seconds: 5, milliseconds: 999)),
          '0:05');
      expect(TimeUtils.formatShort(const Duration(minutes: 3, seconds: 7)), '3:07');
    });

    test('負の値は0として扱う', () {
      expect(TimeUtils.formatShort(const Duration(seconds: -1)), '0:00');
    });
  });

  group('null許容フォーマット', () {
    test('null はプレースホルダを返す', () {
      expect(TimeUtils.formatNullable(null), TimeUtils.nullTime);
      expect(TimeUtils.formatShortNullable(null), TimeUtils.nullTimeShort);
      expect(TimeUtils.formatShortMs(null), TimeUtils.nullTimeShort);
    });

    test('値があれば通常フォーマットと一致する', () {
      const d = Duration(minutes: 2, seconds: 30, milliseconds: 500);
      expect(TimeUtils.formatNullable(d), TimeUtils.format(d));
      expect(TimeUtils.formatShortNullable(d), TimeUtils.formatShort(d));
      expect(TimeUtils.formatShortMs(d.inMilliseconds), TimeUtils.formatShort(d));
    });

    test('formatShortMs は0ミリ秒とnullを区別する', () {
      expect(TimeUtils.formatShortMs(0), '0:00');
      expect(TimeUtils.formatShortMs(null), '--:--');
    });
  });

  group('TimeUtils.parse', () {
    test('M:SS.mmm と M:SS の両方を読める', () {
      expect(TimeUtils.parse('1:30.500'),
          const Duration(minutes: 1, seconds: 30, milliseconds: 500));
      expect(TimeUtils.parse('0:05'), const Duration(seconds: 5));
    });

    test('ミリ秒は右0埋めする（.5 は500ms）', () {
      expect(TimeUtils.parse('0:01.5'), const Duration(seconds: 1, milliseconds: 500));
      expect(TimeUtils.parse('0:01.05'), const Duration(seconds: 1, milliseconds: 50));
    });

    test('形式が合わなければ null', () {
      expect(TimeUtils.parse('invalid'), isNull);
      expect(TimeUtils.parse(''), isNull);
    });

    test('format との往復で値が保たれる', () {
      const d = Duration(minutes: 12, seconds: 34, milliseconds: 567);
      expect(TimeUtils.parse(TimeUtils.format(d)), d);
    });
  });
}
