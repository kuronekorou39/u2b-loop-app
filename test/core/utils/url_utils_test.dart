import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/url_utils.dart';

void main() {
  group('extractVideoId', () {
    test('watch / youtu.be / embed / shorts / live の各形式を読める', () {
      const id = 'dQw4w9WgXcQ';
      expect(UrlUtils.extractVideoId('https://www.youtube.com/watch?v=$id'), id);
      expect(UrlUtils.extractVideoId('https://youtu.be/$id'), id);
      expect(UrlUtils.extractVideoId('https://www.youtube.com/embed/$id'), id);
      expect(UrlUtils.extractVideoId('https://www.youtube.com/shorts/$id'), id);
      expect(UrlUtils.extractVideoId('https://www.youtube.com/live/$id'), id);
    });

    test('クエリが後ろに付いていても取れる', () {
      expect(
        UrlUtils.extractVideoId(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL123'),
        'dQw4w9WgXcQ',
      );
    });

    test('ID にハイフンとアンダースコアを含められる', () {
      expect(UrlUtils.extractVideoId('https://youtu.be/a-b_c1234_X'), 'a-b_c1234_X');
    });

    test('YouTube以外や不正な長さは null', () {
      expect(UrlUtils.extractVideoId('https://example.com/watch?v=dQw4w9WgXcQ'),
          isNull);
      expect(UrlUtils.extractVideoId('https://youtu.be/short'), isNull);
      expect(UrlUtils.extractVideoId(''), isNull);
      expect(UrlUtils.extractVideoId('ただの文字列'), isNull);
    });
  });

  group('extractPlaylistId', () {
    test('list= パラメータを取り出す', () {
      expect(
        UrlUtils.extractPlaylistId(
            'https://www.youtube.com/playlist?list=PLabc123'),
        'PLabc123',
      );
      expect(
        UrlUtils.extractPlaylistId(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz'),
        'PLxyz',
      );
    });

    test('list= が無ければ null', () {
      expect(
        UrlUtils.extractPlaylistId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isNull,
      );
    });
  });
}
