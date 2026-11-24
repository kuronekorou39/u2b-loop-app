import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/media_kind.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/video_source.dart';

void main() {
  test('拡張子で音楽ファイルを見分ける（大文字も）', () {
    expect(MediaKind.isAudioName('a.flac'), isTrue);
    expect(MediaKind.isAudioName('B.MP3'), isTrue);
    expect(MediaKind.isAudioName('c.mp4'), isFalse);
    expect(MediaKind.isAudioName('noext'), isFalse);
    expect(MediaKind.isAudioName('dot.'), isFalse);
  });

  test('content:// でもタイトルの拡張子で見分ける', () {
    final item = LoopItem(
      id: '1',
      title: 'song.m4a',
      uri: 'content://media/external/audio/123',
      sourceType: SourceTypes.local,
    );
    expect(item.isLocalAudio, isTrue);
  });

  test('YouTube は音楽扱いにしない', () {
    const source = VideoSource(
        type: VideoSourceType.youtube, uri: 'https://x/a.mp3', title: 'a.mp3');
    expect(source.isAudioOnly, isFalse);
  });
}
