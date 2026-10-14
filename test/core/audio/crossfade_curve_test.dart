import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';

void main() {
  group('CrossfadeCurve.levels', () {
    for (final c in CrossfadeCurve.values) {
      test('${c.name}: 始まりは前の曲だけ、終わりは次の曲だけ', () {
        final s = c.levels(0);
        expect(s.out, closeTo(1, 1e-9));
        expect(s.in_, closeTo(0, 1e-9));
        final e = c.levels(1);
        expect(e.out, closeTo(0, 1e-9));
        expect(e.in_, closeTo(1, 1e-9));
      });

      test('${c.name}: 範囲外の t はクランプされ、値は 0〜1', () {
        for (final t in [-1.0, -0.1, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5]) {
          final l = c.levels(t);
          expect(l.out, inInclusiveRange(0, 1));
          expect(l.in_, inInclusiveRange(0, 1));
        }
      });
    }

    test('等パワーは中間で合計の音圧が落ちない', () {
      final l = CrossfadeCurve.equalPower.levels(0.5);
      expect(l.out * l.out + l.in_ * l.in_, closeTo(1, 1e-9));
    });

    test('次曲先行は中間で次の曲が 7 割、前の曲はまだ全開', () {
      final l = CrossfadeCurve.nextFirst.levels(0.5);
      expect(l.in_, closeTo(0.7, 1e-9));
      expect(l.out, 1);
      // 入る曲は単調に増える
      var prev = -1.0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final v = CrossfadeCurve.nextFirst.levels(t).in_;
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
    });

    test('カットは切替点まで前の曲のまま', () {
      expect(CrossfadeCurve.cut.levels(0.99), (out: 1, in_: 0));
      expect(CrossfadeCurve.cut.levels(1), (out: 0, in_: 1));
    });
  });

  test('ベーススワップの位置は入る曲が主役になる所', () {
    expect(CrossfadeCurve.equalPower.bassSwapAt, 0.5);
    expect(CrossfadeCurve.linear.bassSwapAt, 0.5);
    expect(CrossfadeCurve.nextFirst.bassSwapAt, 0.7);
    expect(CrossfadeCurve.cut.bassSwapAt, 1.0);
    // 次曲先行ではその時点で入る曲が 7 割に達している
    expect(CrossfadeCurve.nextFirst.levels(0.7).in_, greaterThanOrEqualTo(0.7));
  });

  test('fromName は不明なら既定', () {
    expect(CrossfadeCurve.fromName('nextFirst'), CrossfadeCurve.nextFirst);
    expect(CrossfadeCurve.fromName('x'), CrossfadeCurve.defaultCurve);
    expect(CrossfadeCurve.fromName(null), CrossfadeCurve.defaultCurve);
  });
}
