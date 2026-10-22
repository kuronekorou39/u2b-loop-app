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

  group('canPark（前の曲を 3 台目に残すか）', () {
    test('どちらも 15 分以内なら残す', () {
      expect(
          PlaylistEngine.canPark(
              const Duration(minutes: 4), const Duration(minutes: 15)),
          isTrue);
    });
    test('どちらかが長い・長さが不明なら残さない（2 台で回す）', () {
      expect(
          PlaylistEngine.canPark(
              const Duration(hours: 6), const Duration(minutes: 4)),
          isFalse);
      expect(
          PlaylistEngine.canPark(
              const Duration(minutes: 4), const Duration(minutes: 16)),
          isFalse);
      expect(PlaylistEngine.canPark(Duration.zero, const Duration(minutes: 4)),
          isFalse);
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
    );

    test('入る曲の速度が違う（テンポ合わせ）ときは、その比で進む', () {
      final fast = MixPair(
        outSlot: pair.outSlot,
        outItem: pair.outItem,
        outDuration: pair.outDuration,
        next: pair.next,
        inDuration: pair.inDuration,
        inStart: pair.inStart,
        start: pair.start,
        cut: pair.cut,
        recipe: pair.recipe,
        inRatio: 1.05,
      );
      // 出る曲で 8 秒進むと、入る曲は 8.4 秒進む
      expect(fast.toInClock(const Duration(seconds: 178)),
          const Duration(milliseconds: 13400));
      expect(fast.toOutClock(const Duration(milliseconds: 13400)),
          const Duration(seconds: 178));
    });

    test('入る曲の時計と出る曲の時計を行き来できる', () {
      // 入る曲は交差開始（出る曲 170s）で 5s から鳴り始める
      expect(pair.toOutClock(const Duration(seconds: 5)),
          const Duration(seconds: 170));
      expect(pair.toInClock(const Duration(seconds: 178)),
          const Duration(seconds: 13));
      expect(pair.toInClock(pair.toOutClock(const Duration(seconds: 42))),
          const Duration(seconds: 42));
    });

    test('組の見分けは出る曲と入る曲の id', () {
      expect(pair.key, 'a>b');
    });
  });
}
