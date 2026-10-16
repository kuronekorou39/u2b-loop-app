import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/core/audio/transition_planner.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

/// おまかせが、計画の表どおりにレシピを選ぶこと
void main() {
  LoopItem item({
    double? bpm,
    String? key,
    double? confidence,
    double? headDb = -8,
    double? tailDb = -8,
    double? endFadeDb = 0,
    int? mixInMs = 30000,
    double? dropDb = 7,
  }) =>
      LoopItem(
        id: 'x',
        title: 'x',
        uri: 'x',
        sourceType: 'local',
        bpm: bpm,
        musicalKey: key,
        beatBpm: bpm,
        beatOffsetMs: bpm == null ? null : 0,
        beatConfidence: confidence,
        headDb: headDb,
        tailDb: tailDb,
        endFadeDb: endFadeDb,
        mixInMs: mixInMs,
        dropDb: dropDb,
      );

  test('ビート安定・テンポ近い・同じエネルギー → ブレンド 16 拍 次曲先行 スイープ', () {
    final r = TransitionPlanner.plan(item(bpm: 126), item(bpm: 128));
    expect(r.name, 'ブレンド');
    expect(r.beats, 16);
    expect(r.curve, CrossfadeCurve.nextFirst);
    expect(r.bassSwap, isTrue);
    expect(r.effect, TransitionEffect.filterSweep);
    expect(r.beatMatch, isTrue);
    expect(r.tempoMatch, isTrue);
    expect(r.auto, isTrue);
    expect(r.reason, 'テンポ差 2%');
    expect(r.summary, 'ブレンド（テンポ差 2%）');
  });

  test('入る曲に強いドロップ → ドロップ合わせ 8 拍 カット ライザー＋インパクト', () {
    final r = TransitionPlanner.plan(item(bpm: 128), item(bpm: 128, dropDb: 11));
    expect(r.name, 'ドロップ合わせ');
    expect(r.beats, 8);
    expect(r.curve, CrossfadeCurve.cut);
    expect(r.effect, TransitionEffect.riserImpact);
    expect(r.reason, contains('ドロップ +11dB'));
  });

  test('ミックスイン点が無ければドロップとは見なさない', () {
    final r = TransitionPlanner.plan(
        item(bpm: 128), item(bpm: 128, dropDb: 11, mixInMs: null));
    expect(r.name, 'ブレンド');
  });

  test('入る曲が速い / 大きい → 盛り上げ 8 拍 ライザー', () {
    final faster = TransitionPlanner.plan(item(bpm: 120), item(bpm: 126));
    expect(faster.name, '盛り上げ');
    expect(faster.effect, TransitionEffect.riser);
    expect(faster.curve, CrossfadeCurve.nextFirst);
    expect(faster.reason, 'テンポ差 5% · 入る曲が速い');

    final louder = TransitionPlanner.plan(
        item(bpm: 128, tailDb: -14), item(bpm: 128, headDb: -8));
    expect(louder.name, '盛り上げ');
    expect(louder.reason, 'テンポ差 0% · 入る曲が +6dB');
  });

  test('入る曲が遅い / 静か → 落ち着かせ 16 拍 等パワー エコーアウト', () {
    final slower = TransitionPlanner.plan(item(bpm: 128), item(bpm: 122));
    expect(slower.name, '落ち着かせ');
    expect(slower.beats, 16);
    expect(slower.curve, CrossfadeCurve.equalPower);
    expect(slower.effect, TransitionEffect.echoOut);

    final quieter = TransitionPlanner.plan(
        item(bpm: 128, tailDb: -6), item(bpm: 128, headDb: -12));
    expect(quieter.name, '落ち着かせ');
    expect(quieter.reason, contains('入る曲が -6dB'));
  });

  test('倍/半テンポは同じとみなす', () {
    final r = TransitionPlanner.plan(item(bpm: 128), item(bpm: 64));
    expect(r.name, 'ブレンド');
    expect(r.reason, 'テンポ差 0%');
  });

  test('テンポ差が大きい → 短く切り替え 4 拍 低音入れ替え無し インパクト 合わせない', () {
    final r = TransitionPlanner.plan(item(bpm: 128), item(bpm: 100));
    expect(r.name, '短く切り替え');
    expect(r.beats, 4);
    expect(r.bassSwap, isFalse);
    expect(r.effect, TransitionEffect.impact);
    expect(r.beatMatch, isFalse);
    expect(r.tempoMatch, isFalse);
  });

  test('どちらかのビートが不安定 → ゆるく重ねる 8 拍 何もしない', () {
    final r = TransitionPlanner.plan(
        item(bpm: 128, confidence: 0.1), item(bpm: 128, dropDb: 12));
    expect(r.name, 'ゆるく重ねる');
    expect(r.beats, 8);
    expect(r.effect, TransitionEffect.none);
    expect(r.bassSwap, isFalse);
    expect(r.beatMatch, isFalse);
    expect(r.reason, contains('ビートが不安定'));
  });

  test('出る曲がフェードアウト → フェードアウトに重ねる 16 拍 次曲先行', () {
    final r = TransitionPlanner.plan(item(bpm: 128, endFadeDb: -9), item(bpm: 128, dropDb: 12));
    expect(r.name, 'フェードアウトに重ねる');
    expect(r.curve, CrossfadeCurve.nextFirst);
    expect(r.effect, TransitionEffect.none);
    expect(r.reason, contains('フェードアウト'));
  });

  test('静かな曲同士 → そっと重ねる 4 拍（他の条件より優先）', () {
    final r = TransitionPlanner.plan(
        item(bpm: 70, tailDb: -20), item(bpm: 100, headDb: -22, dropDb: 12));
    expect(r.name, 'そっと重ねる');
    expect(r.beats, 4);
    expect(r.effect, TransitionEffect.none);
    expect(r.beatMatch, isFalse);
  });

  test('テンポ不明 → 標準 8 拍 等パワー スイープ 合わせない', () {
    final r = TransitionPlanner.plan(item(), item(bpm: 128));
    expect(r.name, '標準');
    expect(r.beats, 8);
    expect(r.bassSwap, isTrue);
    expect(r.effect, TransitionEffect.filterSweep);
    expect(r.beatMatch, isFalse);
    expect(r.reason, 'テンポ不明');
  });

  test('音量の流れが未計測でもテンポだけで選べる', () {
    final r = TransitionPlanner.plan(
      item(bpm: 128, headDb: null, tailDb: null, endFadeDb: null, dropDb: null),
      item(bpm: 128, headDb: null, tailDb: null, endFadeDb: null, dropDb: null),
    );
    expect(r.name, 'ブレンド');
  });

  test('キーが合わなければ長いレシピは 8 拍に縮める', () {
    // Cmaj (8B) と F#maj (2B): Camelot で正反対
    final r = TransitionPlanner.plan(
        item(bpm: 128, key: 'Cmaj'), item(bpm: 128, key: 'F#maj'));
    expect(r.name, 'ブレンド');
    expect(r.beats, 8);
    expect(r.reason, contains('キー不一致で短め'));
    // 合うキーなら 16 のまま
    final ok = TransitionPlanner.plan(
        item(bpm: 128, key: 'Cmaj'), item(bpm: 128, key: 'Gmaj'));
    expect(ok.beats, 16);
  });
}
