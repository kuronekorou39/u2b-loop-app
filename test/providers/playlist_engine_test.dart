import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/core/audio/transition_planner.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist_track.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/providers/playlist_engine.dart';

LoopItem _item(String id, {int? trailingSilenceMs}) => LoopItem(
      id: id,
      title: '曲$id',
      uri: 'https://example.com/$id',
      sourceType: SourceTypes.youtube,
      videoId: id,
      trailingSilenceMs: trailingSilenceMs,
    );

/// 先読みを始める残り時間（再生画面の判定と重ね表示の準備線が共用する式）
void main() {
  group('preloadLead', () {
    test('短い曲は 10 秒前、2 分を超える曲は 30 秒前', () {
      expect(
        PlaylistEngine.preloadLead(
          item: _item('a'),
          endPoint: const Duration(seconds: 90),
          firstVerse: false,
          fade: Duration.zero,
        ),
        const Duration(seconds: 10),
      );
      expect(
        PlaylistEngine.preloadLead(
          item: _item('a'),
          endPoint: const Duration(minutes: 4),
          firstVerse: false,
          fade: Duration.zero,
        ),
        const Duration(seconds: 30),
      );
    });

    test('1 番だけモードは B 点の 30 秒前（クロスフェードは足さない）', () {
      expect(
        PlaylistEngine.preloadLead(
          item: _item('a'),
          endPoint: const Duration(seconds: 60),
          firstVerse: true,
          fade: const Duration(seconds: 40),
        ),
        const Duration(seconds: 30),
      );
    });

    test('クロスフェード + 曲末の無音 + 10 秒のほうが長ければそちら', () {
      expect(
        PlaylistEngine.preloadLead(
          item: _item('a', trailingSilenceMs: 2500),
          endPoint: const Duration(minutes: 4),
          firstVerse: false,
          fade: const Duration(seconds: 24),
        ),
        // 24 + 3（切り上げ）+ 10 = 37 > 30
        const Duration(seconds: 37),
      );
    });
  });

  group('endPointFor（準備線を引く入る曲の終点）', () {
    const dur = Duration(minutes: 4);
    test('1 番だけモードでなければ曲の最後', () {
      expect(
          PlaylistEngine.endPointFor(
              duration: dur, firstVerseMode: false, regionEndMs: 60000),
          (dur, false));
    });
    test('区間の B 点 → ループの B 点 → 手で直した 1 番の順に使う', () {
      expect(
          PlaylistEngine.endPointFor(
              duration: dur,
              firstVerseMode: true,
              regionEndMs: 60000,
              liveB: const Duration(seconds: 70),
              savedFirstVerseBMs: 80000),
          (const Duration(seconds: 60), true));
      expect(
          PlaylistEngine.endPointFor(
              duration: dur,
              firstVerseMode: true,
              liveB: const Duration(seconds: 70),
              savedFirstVerseBMs: 80000),
          (const Duration(seconds: 70), true));
      expect(
          PlaylistEngine.endPointFor(
              duration: dur, firstVerseMode: true, savedFirstVerseBMs: 80000),
          (const Duration(seconds: 80), true));
    });
    test('区間の無い曲で 1 番の終わりが未定なら曲の最後（後で計算し直す）', () {
      expect(PlaylistEngine.endPointFor(duration: dur, firstVerseMode: true),
          (dur, false));
    });
  });

  group('MixPair', () {
    final pair = MixPair(
      outSlot: ActiveSlot.a,
      outItem: _item('a'),
      outDuration: const Duration(minutes: 3),
      next: PlaylistTrack(item: _item('b'), itemIndex: 1),
      inDuration: const Duration(minutes: 4),
      inStart: const Duration(seconds: 5),
      start: const Duration(seconds: 170),
      cut: const Duration(seconds: 178),
      recipe: const TransitionRecipe(
        beats: 16,
        curve: CrossfadeCurve.defaultCurve,
        bassSwap: false,
        effect: TransitionEffect.none,
        beatMatch: false,
        tempoMatch: false,
      ),
      prepLine: const Duration(seconds: 380),
    );

    test('入る曲の時計と出る曲の時計を行き来できる', () {
      // 入る曲は交差開始（出る曲 170s）で 5s から鳴り始める
      expect(pair.toOutClock(const Duration(seconds: 5)),
          const Duration(seconds: 170));
      expect(pair.toInClock(const Duration(seconds: 178)),
          const Duration(seconds: 13));
      expect(pair.toInClock(pair.toOutClock(const Duration(seconds: 42))),
          const Duration(seconds: 42));
    });

    test('withPrepLine は準備線だけ差し替える', () {
      final moved = pair.withPrepLine(null);
      expect(moved.prepLine, isNull);
      expect(moved.key, pair.key);
      expect(moved.toOutClock(const Duration(seconds: 5)),
          const Duration(seconds: 170));
      expect(pair.withPrepLine(const Duration(seconds: 200)).prepLine,
          const Duration(seconds: 200));
    });

    test('組の見分けは出る曲と入る曲の id', () {
      expect(pair.key, 'a>b');
    });
  });
}
