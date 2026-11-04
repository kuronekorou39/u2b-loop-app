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
    testWidgets('時刻は両端、開閉ボタンは真ん中（左の枠に倍率、右の枠にデッキ）', (tester) async {
      var toggled = 0;
      await tester.pumpWidget(host(SeekTimeRow(
        position: const Duration(seconds: 65),
        duration: const Duration(minutes: 3),
        onToggleCompact: () => toggled++,
        leading: ZoomStepper(label: '4x', onMinus: () {}, onPlus: () {}),
        trailing: const Icon(Icons.album, key: Key('wheels')),
      )));
      expect(find.text('1:05.000'), findsOneWidget);
      expect(find.text('3:00.000'), findsOneWidget);
      final rowCenter = tester.getCenter(find.byType(SeekTimeRow));
      final toggle = find.widgetWithIcon(IconButton, Icons.unfold_less);
      expect(tester.getCenter(toggle).dx, closeTo(rowCenter.dx, 1));
      // 右の枠にデッキ（開閉ボタンのすぐ右）
      final wheels = tester.getCenter(find.byKey(const Key('wheels')));
      expect(wheels.dx, greaterThan(rowCenter.dx));
      expect(wheels.dx, lessThan(rowCenter.dx + SeekTimeRow.sideWidth + 18));
      // 左の枠に倍率
      expect(tester.getCenter(find.text('4x')).dx, lessThan(rowCenter.dx));
      await tester.tap(toggle);
      expect(toggled, 1);
    });

    testWidgets('右の枠が空でも開閉ボタンは真ん中（単体再生で追従が出ていないとき）', (tester) async {
      await tester.pumpWidget(host(SeekTimeRow(
        position: Duration.zero,
        duration: const Duration(minutes: 3),
        onToggleCompact: () {},
        leading: ZoomStepper(label: '1.0x', onMinus: null, onPlus: () {}),
      )));
      final rowCenter = tester.getCenter(find.byType(SeekTimeRow));
      final toggle = find.widgetWithIcon(IconButton, Icons.unfold_less);
      expect(tester.getCenter(toggle).dx, closeTo(rowCenter.dx, 1));
    });
  });

  testWidgets('倍率の欄は桁が変わっても幅が同じ', (tester) async {
    Future<double> widthOf(String label) async {
      await tester.pumpWidget(host(Center(
          child: ZoomStepper(label: label, onMinus: () {}, onPlus: () {}))));
      return tester.getSize(find.byType(ZoomStepper)).width;
    }

    final one = await widthOf('1.0x');
    expect(await widthOf('128x'), one);
    expect(await widthOf('32x'), one);
    expect(one, ZoomStepper.width);
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
