import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/playback/hq_audio.dart';

void main() {
  group('HqAudio.pickIndex', () {
    test('mp4 の中で最高ビットレートを選ぶ（webm の方が高くても mp4 優先）', () {
      final i = HqAudio.pickIndex([
        (mp4: true, bps: 49_000), // itag 139
        (mp4: false, bps: 145_000), // itag 251 Opus
        (mp4: true, bps: 128_000), // itag 140
        (mp4: false, bps: 62_000), // itag 249
      ]);
      expect(i, 2);
    });

    test('mp4 が無ければ webm の最高ビットレート', () {
      final i = HqAudio.pickIndex([
        (mp4: false, bps: 62_000),
        (mp4: false, bps: 145_000),
      ]);
      expect(i, 1);
    });

    test('候補が無ければ -1', () {
      expect(HqAudio.pickIndex([]), -1);
    });
  });

  test('一体型の音声（96kbps）を超えないストリームは付けない', () {
    expect(HqAudio.muxedAudioKbps, 96);
    expect(HqAudio.isWorthItKbps(128), isTrue);
    expect(HqAudio.isWorthItKbps(96), isFalse);
    expect(HqAudio.isWorthItKbps(49), isFalse);
  });

  test('fetch の Future は必ず完了する（取れないときは null）', () async {
    // テスト環境では一時領域が取れないので取得は失敗するが、Future 自体は完了すること。
    // 以前は whenComplete が remove の戻り値（自分自身）を待って永遠に完了しなかった
    final result =
        await HqAudio.fetch('no-such-video').timeout(const Duration(seconds: 5));
    expect(result, isNull);
    // 2 回目も同じ（進行中の記録が残っていない）
    final again =
        await HqAudio.fetch('no-such-video').timeout(const Duration(seconds: 5));
    expect(again, isNull);
  });

  group('HqAudio.labelFor', () {
    test('ファイル名からコーデックとビットレートを読む', () {
      expect(HqAudio.labelFor('/c/hq_audio/abc123.140.128k.mp4'), 'AAC 128kbps');
      expect(HqAudio.labelFor(r'C:\t\hq_audio\abc.251.145k.webm'), 'Opus 145kbps');
    });

    test('読めない名前は「音声専用」', () {
      expect(HqAudio.labelFor('/c/hq_audio/abc.mp4'), '音声専用');
    });
  });

  group('HqAudio.isManagedPath', () {
    test('hq_audio ディレクトリ配下だけ管理下（区切りは / でも \\ でも）', () {
      expect(HqAudio.isManagedPath('/data/cache/hq_audio/abc.mp4'), isTrue);
      expect(HqAudio.isManagedPath(r'C:\tmp\hq_audio\abc.mp4'), isTrue);
      expect(
          HqAudio.isManagedPath('/data/cache/u2b_waveform_1.tmp'), isFalse);
      expect(HqAudio.isManagedPath('/data/hq_audio_old/abc.mp4'), isFalse);
    });
  });
}
