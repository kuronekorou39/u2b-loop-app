import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/providers/loop_provider.dart';
import 'package:u2b_loop_app/widgets/player/dj_mix_controls.dart';

/// おまかせ中の長さのつまみと、曲の後の無音を飛ばす位置
void main() {
  group('長さのつまみ', () {
    test('おまかせ中は オフ / 自動 / 16小節 / 32小節', () {
      expect(DjMixControls.crossfadeSteps(auto: true), [0, 8, 64, 128]);
      for (final beats in [4, 8, 16, 32]) {
        expect(DjMixControls.crossfadeLabel(beats, auto: true), '自動');
        expect(DjMixControls.crossfadeStepIndex(beats, auto: true), 1);
      }
      expect(DjMixControls.crossfadeLabel(64, auto: true), '16小節');
      expect(DjMixControls.crossfadeStepIndex(128, auto: true), 3);
    });

    test('おまかせを切ると手で決めていた長さに戻る', () {
      expect(DjMixControls.crossfadeAtStep(1, 16, auto: true), 16);
      expect(DjMixControls.crossfadeLabel(16), '16拍');
      expect(DjMixControls.crossfadeStepIndex(16, auto: false), 3);
      expect(DjMixControls.crossfadeAtStep(1, 64, auto: true), 8);
    });
  });

  group('曲の後の無音', () {
    const d = Duration(minutes: 4);
    test('1 秒以上の無音はその頭から飛ばす', () {
      expect(LoopNotifier.silenceSkipAt(d, 8000), const Duration(seconds: 232));
    });
    test('短い無音・未計測・全部が無音は飛ばさない', () {
      expect(LoopNotifier.silenceSkipAt(d, 900), isNull);
      expect(LoopNotifier.silenceSkipAt(d, null), isNull);
      expect(LoopNotifier.silenceSkipAt(d, 240000), isNull);
    });
  });
}
