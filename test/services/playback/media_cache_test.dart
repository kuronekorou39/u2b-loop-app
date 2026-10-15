import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/playback/hq_audio.dart';
import 'package:u2b_loop_app/services/playback/media_cache.dart';

void main() {
  final t0 = DateTime(2026, 10, 16);
  CacheEntry e(String name, int mb, int minutesAgo) =>
      CacheEntry(name, mb * 1024 * 1024, t0.subtract(Duration(minutes: minutesAgo)));
  const mb = 1024 * 1024;

  group('MediaCache.pickEvictions', () {
    test('上限以下なら何も消さない', () {
      expect(MediaCache.pickEvictions([e('a.v18.mp4', 10, 1), e('b.v18.mp4', 10, 2)], 100 * mb),
          isEmpty);
    });

    test('上限を超えたら古い順に消す', () {
      final out = MediaCache.pickEvictions([
        e('new.v18.mp4', 40, 1),
        e('mid.v18.mp4', 40, 5),
        e('old.v18.mp4', 40, 9),
      ], 100 * mb);
      expect(out, ['old.v18.mp4']);
    });

    test('長い曲の印付きは新しい 2 件だけ残し、上限の計算からも外れる', () {
      final out = MediaCache.pickEvictions([
        e('l1.140.128k.long.mp4', 50, 1),
        e('l2.140.128k.long.mp4', 50, 2),
        e('l3.140.128k.long.mp4', 50, 3),
        e('a.v18.mp4', 10, 4),
      ], 1000 * mb);
      expect(out, ['l3.140.128k.long.mp4']);
    });
  });

  test('長さの見積もり: 128kbps で 4.7MB ≒ 4 分 54 秒、15 分超は長い曲', () {
    final d = MediaCache.estimateDuration(4733433, 128000);
    expect(d.inSeconds, inInclusiveRange(290, 300));
    expect(MediaCache.isTooLong(d), isFalse);
    expect(MediaCache.isTooLong(const Duration(minutes: 16)), isTrue);
  });

  test('長い曲の音声の名前にも素性が読める', () {
    expect(HqAudio.fileNameForParts('abc', 140, 128, 'mp4', long: true),
        'abc.140.128k.long.mp4');
    expect(HqAudio.labelFor('/c/media_cache/abc.140.128k.long.mp4'), 'AAC 128kbps');
    expect(HqAudio.isManagedPath('/data/cache/media_cache/abc.v18.mp4'), isTrue);
  });
}
