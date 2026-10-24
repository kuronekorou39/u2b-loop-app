import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/loop/loop_seekbar.dart';
import 'package:u2b_loop_app/widgets/player/playlist_seek_area.dart';

/// 重ね表示が組む部品: 細い棒 1 本・時刻行・出す範囲の余白
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, child: child)),
      );

  group('ThinSeekbar', () {
    testWidgets('押した位置を曲の長さに割り当てて返す。onSeek が無ければ見るだけ', (tester) async {
      Duration? seeked;
      await tester.pumpWidget(host(ThinSeekbar(
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 100),
        onSeek: (d) => seeked = d,
      )));
      final bar = find.byType(ThinSeekbar);
      final left = tester.getTopLeft(bar);
      final w = tester.getSize(bar).width;
      await tester.tapAt(left + Offset(w * 0.25, 10));
      expect(seeked, const Duration(seconds: 25));

      seeked = null;
      await tester.pumpWidget(host(const ThinSeekbar(
        position: Duration(seconds: 10),
        duration: Duration(seconds: 100),
      )));
      await tester.tapAt(left + Offset(w * 0.25, 10));
      expect(seeked, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('SeekTimeRow', () {
    testWidgets('時刻は両端、開閉ボタンは真ん中（左の枠に円盤の開閉、右に −/＋）', (tester) async {
      var toggled = 0, wider = 0;
      await tester.pumpWidget(host(SeekTimeRow(
        position: const Duration(seconds: 65),
        duration: const Duration(minutes: 3),
        onToggleCompact: () => toggled++,
        zoom: (wider: () => wider++, narrower: null),
        leading: const Icon(Icons.album, key: Key('wheels')),
      )));
      expect(find.text('1:05.000'), findsOneWidget);
      expect(find.text('3:00.000'), findsOneWidget);
      final rowCenter = tester.getCenter(find.byType(SeekTimeRow));
      final toggle = find.widgetWithIcon(IconButton, Icons.unfold_less);
      expect(tester.getCenter(toggle).dx, closeTo(rowCenter.dx, 1));
      // 左の枠に円盤の開閉、右の枠に −/＋
      expect(tester.getCenter(find.byKey(const Key('wheels'))).dx,
          lessThan(rowCenter.dx));
      expect(tester.getCenter(find.byIcon(Icons.remove)).dx,
          greaterThan(rowCenter.dx));
      await tester.tap(toggle);
      await tester.tap(find.byIcon(Icons.remove));
      expect(toggled, 1);
      expect(wider, 1);
    });
  });

  group('triggerMarginFor（重ね表示を出す範囲の余白）', () {
    test('窓の余白の 2.5 倍、ただし 10 秒は下回らない', () {
      expect(PlaylistSeekArea.triggerMarginFor(const Duration(seconds: 8)),
          const Duration(seconds: 20));
      expect(PlaylistSeekArea.triggerMarginFor(const Duration(seconds: 4)),
          const Duration(seconds: 10));
      // 一番狭い窓（余白 0）でも 10 秒手前から出す
      expect(PlaylistSeekArea.triggerMarginFor(Duration.zero),
          const Duration(seconds: 10));
      expect(PlaylistSeekArea.triggerMarginFor(const Duration(seconds: 64)),
          const Duration(seconds: 160));
    });
  });
}
