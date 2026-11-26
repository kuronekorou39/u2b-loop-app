import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// media_kit の Video は既定で「アプリが裏に回ったら一時停止」する。
/// このアプリは裏（PiP・画面オフ）でも鳴らすので、どの Video でも切っておく
void main() {
  test('lib の Video はすべて pauseUponEnteringBackgroundMode: false', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\bVideo\(').allMatches(src)) {
        // 呼び出しの括弧の中だけを見る
        var depth = 0;
        var end = m.end - 1;
        for (; end < src.length; end++) {
          if (src[end] == '(') depth++;
          if (src[end] == ')' && --depth == 0) break;
        }
        final call = src.substring(m.start, end);
        if (!call.contains('pauseUponEnteringBackgroundMode: false')) {
          offenders.add(f.path);
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
