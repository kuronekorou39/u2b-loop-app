import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/subtitle_service.dart';

SubtitleEntry _entry(String text, int startMs, int durationMs) => SubtitleEntry(
      text: text,
      offset: Duration(milliseconds: startMs),
      duration: Duration(milliseconds: durationMs),
    );

void main() {
  group('SRTの往復', () {
    test('文字列・開始・終了が保たれる', () {
      final entries = [
        _entry('最初の行', 0, 1500),
        _entry('次の行', 2000, 3000),
      ];
      final parsed = SubtitleService.parseSrt(SubtitleService.toSrt(entries));

      expect(parsed, hasLength(2));
      for (var i = 0; i < entries.length; i++) {
        expect(parsed[i].text, entries[i].text);
        expect(parsed[i].offset, entries[i].offset);
        expect(parsed[i].end, entries[i].end);
      }
    });

    test('1時間を超える位置でも壊れない', () {
      final entries = [_entry('遅い行', 3661000, 2000)]; // 1:01:01.000
      final parsed = SubtitleService.parseSrt(SubtitleService.toSrt(entries));
      expect(parsed.single.offset, const Duration(milliseconds: 3661000));
      expect(parsed.single.end, const Duration(milliseconds: 3663000));
    });

    test('日本語・絵文字が保たれる', () {
      final entries = [_entry('日本語と 🎵 絵文字', 1000, 1000)];
      final parsed = SubtitleService.parseSrt(SubtitleService.toSrt(entries));
      expect(parsed.single.text, '日本語と 🎵 絵文字');
    });

    test('空リストは空文字列になり、往復しても空', () {
      expect(SubtitleService.parseSrt(SubtitleService.toSrt([])), isEmpty);
    });
  });

  group('parseSrt の耐性', () {
    test('CRLF 改行を読める', () {
      const srt = '1\r\n00:00:01,000 --> 00:00:02,000\r\nテスト\r\n\r\n';
      final parsed = SubtitleService.parseSrt(srt);
      expect(parsed.single.text, 'テスト');
      expect(parsed.single.offset, const Duration(seconds: 1));
    });

    test('インデックス行が無くても読める', () {
      const srt = '00:00:01,000 --> 00:00:02,000\nインデックスなし\n';
      final parsed = SubtitleService.parseSrt(srt);
      expect(parsed.single.text, 'インデックスなし');
    });

    test('複数行のテキストを1エントリにまとめる', () {
      const srt = '1\n00:00:01,000 --> 00:00:03,000\n1行目\n2行目\n';
      final parsed = SubtitleService.parseSrt(srt);
      expect(parsed.single.text, contains('1行目'));
      expect(parsed.single.text, contains('2行目'));
    });

    test('壊れた入力でも例外を投げない', () {
      expect(SubtitleService.parseSrt(''), isEmpty);
      expect(SubtitleService.parseSrt('ただの文章\nもう1行'), isEmpty);
      expect(() => SubtitleService.parseSrt('1\n不正な時刻\nテキスト'),
          returnsNormally);
    });
  });
}
