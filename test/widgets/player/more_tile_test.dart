import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/widgets/player/more_tile.dart';
import 'package:u2b_loop_app/widgets/player/player_more_sheet.dart';

/// 「その他」メニューのタイル: 幅に合わせて列が決まり（縦 3 列・低い画面は 1 行）、
/// オンオフで場所が動かず色だけ変わる、速度のタイルはその場のメニューで選ぶ
void main() {
  Future<void> pump(WidgetTester tester, Widget child, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: Center(child: child)),
    ));
    await tester.pumpAndSettle();
  }

  List<Widget> sixTiles() => [
        for (var i = 1; i <= 6; i++)
          MoreTile(icon: Icons.star, label: 'タイル $i', onTap: () {}),
      ];

  Rect tileRect(WidgetTester tester, String label) =>
      tester.getRect(find.ancestor(
          of: find.text(label), matching: find.byType(MoreTile)));

  testWidgets('縦の電話では 3 列の正方形（4 つ目は次の行）', (tester) async {
    await pump(tester, MoreTileGrid(tiles: sixTiles()),
        size: const Size(400, 800));
    final t1 = tileRect(tester, 'タイル 1');
    final t3 = tileRect(tester, 'タイル 3');
    final t4 = tileRect(tester, 'タイル 4');
    expect(t1.width, closeTo(t1.height, 0.5), reason: '正方形');
    expect(t1.width, greaterThan(100), reason: 'デカいボタン');
    expect(t3.top, t1.top);
    expect(t4.top, greaterThan(t1.bottom));
    expect(t4.left, t1.left, reason: '2 行目は 1 列目から');
  });

  testWidgets('低い画面（横向きの電話）では小さめにして 6 つが 1 行に入る', (tester) async {
    await pump(
        tester,
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: MoreTileGrid(tiles: sixTiles()),
        ),
        size: const Size(800, 360));
    final t1 = tileRect(tester, 'タイル 1');
    final t6 = tileRect(tester, 'タイル 6');
    expect(t6.top, t1.top, reason: '全部同じ行');
    expect(t1.width, lessThanOrEqualTo(MoreTileGrid.maxExtentShort));
  });

  testWidgets('オンオフで場所は動かず、オンのとき緑', (tester) async {
    var on = false;
    await pump(
        tester,
        StatefulBuilder(
          builder: (ctx, setState) => MoreTileGrid(tiles: [
            MoreTile(
              icon: Icons.videocam_outlined,
              label: '動画',
              active: on,
              onTap: () => setState(() => on = !on),
            ),
            MoreTile(icon: Icons.star, label: 'ほか', onTap: () {}),
          ]),
        ),
        size: const Size(400, 800));
    Color iconColor() =>
        tester.widget<Icon>(find.byIcon(Icons.videocam_outlined)).color!;
    final before = tileRect(tester, '動画');
    expect(iconColor(), isNot(AppTheme.accentGreen));
    await tester.tap(find.text('動画'));
    await tester.pumpAndSettle();
    expect(on, isTrue);
    expect(iconColor(), AppTheme.accentGreen);
    expect(tileRect(tester, '動画'), before);
  });

  testWidgets('押せないタイルは onTap が呼ばれず、値は薄い色のまま出る', (tester) async {
    var taps = 0;
    await pump(
        tester,
        MoreTileGrid(tiles: [
          MoreTile(
              icon: Icons.speaker,
              label: '出力',
              value: 'スピーカー',
              enabled: false,
              onTap: () => taps++),
        ]),
        size: const Size(400, 800));
    expect(find.text('スピーカー'), findsOneWidget);
    await tester.tap(find.text('出力'));
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('速度のタイルは今の値を出し、押すとその場のメニューで選べる', (tester) async {
    double? picked;
    await pump(
        tester,
        MoreTileGrid(tiles: [
          SpeedTile(rate: 1.0, onChanged: (s) => picked = s),
        ]),
        size: const Size(400, 800));
    expect(find.text('1.0x'), findsOneWidget);
    await tester.tap(find.text('速度'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(picked, 1.5);
    expect(find.byType(PopupMenuItem<double>), findsNothing);
  });
}
