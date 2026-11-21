import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/band_swap.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/core/audio/transition_planner.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/services/audio_filters.dart';

/// 帯域の入れ替え（低音だけ / 高・中・低）
void main() {
  test('3 帯域は高音 → 中音 → 低音の順。低音の位置は曲線のとおり', () {
    for (final curve in CrossfadeCurve.values) {
      final high = BandSwap.highAt(curve);
      final mid = BandSwap.midAt(curve);
      expect(high, lessThan(mid), reason: curve.name);
      expect(mid, lessThan(curve.bassSwapAt), reason: curve.name);
    }
    expect(BandSwap.highAt(CrossfadeCurve.melt), 0.25);
    expect(BandSwap.midAt(CrossfadeCurve.melt), 0.375);
  });

  test('fromName: 不明なら低音だけ', () {
    expect(BandSwap.fromName('three'), BandSwap.three);
    expect(BandSwap.fromName('none'), BandSwap.none);
    expect(BandSwap.fromName('bogus'), BandSwap.bass);
    expect(BandSwap.fromName(null), BandSwap.bass);
  });

  test('入れ替えのゲインは 0dB から切った値まで', () {
    expect(AudioFilters.bandDb(0), 0);
    expect(AudioFilters.bandDb(1), AudioFilters.bandCutDb);
    expect(AudioFilters.bandDb(2), AudioFilters.bandCutDb);
  });

  group('レシピ', () {
    TransitionRecipe recipe(TransitionEffect effect, BandSwap bands) => TransitionRecipe(
          beats: 16,
          curve: CrossfadeCurve.nextFirst,
          bands: bands,
          effect: effect,
          beatMatch: true,
          tempoMatch: true,
        );

    test('切替点で前の曲を止める演出は、曲線をカットにして帯域は入れ替えない', () {
      final echo = recipe(TransitionEffect.echoTail, BandSwap.three);
      expect(echo.effectiveCurve, CrossfadeCurve.cut);
      expect(echo.effectiveBands, BandSwap.none);
      final brake = recipe(TransitionEffect.brake, BandSwap.bass);
      expect(brake.effectiveCurve, CrossfadeCurve.cut);
      expect(brake.effectiveBands, BandSwap.none);
    });

    test('ふつうの演出は設定のまま', () {
      final r = recipe(TransitionEffect.crash, BandSwap.three);
      expect(r.effectiveCurve, CrossfadeCurve.nextFirst);
      expect(r.effectiveBands, BandSwap.three);
      expect(r.bassSwap, isTrue);
      expect(recipe(TransitionEffect.none, BandSwap.none).bassSwap, isFalse);
    });
  });

  group('設定の引き継ぎ', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('u2b_band_swap_test');
      Hive.init(dir.path);
      await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('v1.158 までのベーススワップ: オフ → なし、オン・未設定 → 低音', () {
      expect(BandSwapNotifier().state, BandSwap.bass);
      AppBoxes.settings.put(SettingsKeys.bassSwap, true);
      expect(BandSwapNotifier().state, BandSwap.bass);
      AppBoxes.settings.put(SettingsKeys.bassSwap, false);
      expect(BandSwapNotifier().state, BandSwap.none);
    });

    test('新しい設定があればそれ（名前で保存）', () {
      AppBoxes.settings.put(SettingsKeys.bassSwap, false);
      final n = BandSwapNotifier()..value = BandSwap.three;
      expect(n.state, BandSwap.three);
      expect(AppBoxes.settings.get(SettingsKeys.bandSwap), 'three');
      expect(BandSwapNotifier().state, BandSwap.three);
    });
  });
}
