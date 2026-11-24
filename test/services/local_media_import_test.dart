import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/local_media_import.dart';

void main() {
  group('LocalMediaImport.uniqueName', () {
    final now = DateTime.fromMicrosecondsSinceEpoch(1234567);

    test('拡張子を残して先頭に時刻を付ける', () {
      expect(LocalMediaImport.uniqueName('song.flac', now), '1234567_song.flac');
    });

    test('パスの区切りは _ に置き換える', () {
      expect(LocalMediaImport.uniqueName('a/b\\c:d.mp4', now), '1234567_a_b_c_d.mp4');
    });
  });

  test('音楽の形式も選べる', () {
    expect(LocalMediaImport.extensions, containsAll(['flac', 'mp3', 'm4a', 'mp4']));
  });
}
