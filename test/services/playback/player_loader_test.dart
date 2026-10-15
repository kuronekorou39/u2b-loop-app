import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/video_source.dart';
import 'package:u2b_loop_app/services/playback/player_loader.dart';

/// 曲をどのソースとして開くか（再生画面と AB 設定画面で同じ判断になる）
void main() {
  LoopItem youtube() => LoopItem(
        id: 'y1',
        title: 'YT 曲',
        uri: 'https://youtu.be/abcdefghijk',
        sourceType: SourceTypes.youtube,
        videoId: 'abcdefghijk',
        thumbnailUrl: 'https://i.ytimg.com/vi/abcdefghijk/hq.jpg',
      );
  LoopItem local() => LoopItem(
        id: 'l1',
        title: 'ローカル曲',
        uri: '/sdcard/Music/a.mp4',
        sourceType: SourceTypes.local,
      );

  test('オフライン保存があれば種別は youtube のまま URI だけローカルファイル', () {
    final s = PlayerLoader.sourceFor(youtube(), offlinePath: '/cache/v.mp4');
    expect(s.type, VideoSourceType.youtube);
    expect(s.uri, '/cache/v.mp4');
    expect(s.videoId, 'abcdefghijk');
    expect(s.thumbnailUrl, isNotNull);
  });

  test('YouTube は解決したストリーム URL で開く', () {
    final s = PlayerLoader.sourceFor(youtube(),
        streamUrl: 'https://rr1.googlevideo.com/videoplayback?x=1');
    expect(s.type, VideoSourceType.youtube);
    expect(s.uri, startsWith('https://rr1.googlevideo.com/'));
    expect(s.title, 'YT 曲');
  });

  test('ローカルはそのままの URI。videoId は持たない', () {
    final s = PlayerLoader.sourceFor(local());
    expect(s.type, VideoSourceType.local);
    expect(s.uri, '/sdcard/Music/a.mp4');
    expect(s.videoId, isNull);
  });

  test('オフライン保存はローカル曲より優先されない（ローカルに offlinePath は来ない想定だが、来ても壊れない）',
      () {
    final s = PlayerLoader.sourceFor(local(), offlinePath: '/cache/v.mp4');
    expect(s.uri, '/cache/v.mp4');
  });
}
