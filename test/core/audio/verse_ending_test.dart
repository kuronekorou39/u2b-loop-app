import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/band_swap.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/core/audio/transition_planner.dart';
import 'package:u2b_loop_app/core/audio/verse_ending.dart';

void main() {
  test('保存の名前から戻す。無い・知らない名前は重ねる', () {
    expect(VerseEnding.fromName(null), VerseEnding.overlap);
    expect(VerseEnding.fromName('???'), VerseEnding.overlap);
    expect(VerseEnding.fromName('echo'), VerseEnding.echo);
    expect(VerseEnding.fromName('reverb'), VerseEnding.reverb);
  });

  group('verseTail', () {
    test('重ねるならレシピは無い（ふだんのつなぎ）', () {
      expect(TransitionPlanner.verseTail(VerseEnding.overlap, rendered: true), isNull);
    });

    test('尾の音ができていなければ無い（B 点でぶつ切れにしない）', () {
      expect(TransitionPlanner.verseTail(VerseEnding.echo, rendered: false), isNull);
      expect(TransitionPlanner.verseTail(VerseEnding.reverb, rendered: false), isNull);
    });

    test('エコー・残響は、次の曲を切替点まで止めて、テンポも帯域も触らない', () {
      for (final (ending, effect) in [
        (VerseEnding.echo, TransitionEffect.echoTail),
        (VerseEnding.reverb, TransitionEffect.reverbTail),
      ]) {
        final r = TransitionPlanner.verseTail(ending, rendered: true)!;
        expect(r.effect, effect);
        expect(r.holdsIn, isTrue);
        expect(r.effectiveCurve, CrossfadeCurve.cut);
        expect(r.effectiveBands, BandSwap.none);
        expect(r.beatMatch, isFalse);
        expect(r.tempoMatch, isFalse);
        expect(r.copyWith(beats: 4).holdsIn, isTrue);
      }
    });
  });
}
