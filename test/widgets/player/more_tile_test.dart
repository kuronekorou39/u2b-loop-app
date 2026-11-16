import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/widgets/player/more_tile.dart';
import 'package:u2b_loop_app/widgets/player/player_more_sheet.dart';

/// 「その他」メニューのタイル: 幅に合わせて列が決まり（縦 3 列・低い画面は 1 行）、
/// オンオフで場所が動かず（面は塗り分けない）、速度のタイルはその場のメニューで選ぶ
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

  testWidgets('オンオフで場所は動かず、面の色も変えない。「オン」「オフ」と書き、オフの間だけアイコンが灰色',
      (tester) async {
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
    Color fillOf(String label) => tester
        .widget<Material>(find
            .descendant(
                of: find.ancestor(
                    of: find.text(label), matching: find.byType(MoreTile)),
                matching: find.byType(Material))
            .first)
        .color!;
    final before = tileRect(tester, '動画');
    expect(iconColor(), isNot(AppTheme.accentGreen));
    expect(find.text('オフ'), findsOneWidget);
    expect(fillOf('動画'), fillOf('ほか'));
    // オンオフでないタイルのアイコンは緑、値は出ない
    expect(tester.widget<Icon>(find.byIcon(Icons.star)).color,
        AppTheme.accentGreen);
    await tester.tap(find.text('動画'));
    await tester.pumpAndSettle();
    expect(on, isTrue);
    expect(iconColor(), AppTheme.accentGreen);
    expect(find.text('オン'), findsOneWidget);
    expect(fillOf('動画'), fillOf('ほか'));
    expect(tileRect(tester, '動画'), before);
  });

  testWidgets('アイコンはタイルに合わせて大きく、中身は真ん中。小さいタイルでも溢れない', (tester) async {
    for (final side in [80.0, 110.0, 180.0, 300.0]) {
      await pump(
          tester,
          SizedBox(
            width: side,
            height: side,
            child: MoreTile(
                icon: Icons.star, label: 'ラベル', value: '値', onTap: () {}),
          ),
          size: const Size(400, 800));
      expect(tester.takeException(), isNull, reason: '$side');
      final tile = tester.getRect(find.byType(MoreTile));
      final icon = tester.getRect(find.byIcon(Icons.star));
      expect(icon.center.dx, closeTo(tile.center.dx, 0.5));
      expect(tester.getRect(find.text('ラベル')).center.dx,
          closeTo(tile.center.dx, 0.5));
      if (side >= 110 && side <= 180) {
        expect(icon.width, greaterThanOrEqualTo(side * 0.3), reason: '$side');
      }
    }
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

  testWidgets('開くタイルにも選ぶタイルにも矢印は付けない。選ぶタイルは今の値を出す', (tester) async {
    await pump(
        tester,
        MoreTileGrid(tiles: [
          MoreTile(
              icon: Icons.tune,
              label: 'AB区間',
              onTap: () {}),
          PickerTile<int>(
            icon: Icons.campaign,
            label: '効果音',
            values: const [1, 2],
            selected: 2,
            labelOf: (v) => '値$v',
            onPicked: (_) {},
          ),
        ]),
        size: const Size(400, 800));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    expect(find.text('値2'), findsOneWidget);
  });

  testWidgets('小さめのタイルは少し横長で、縦の電話では幅が違っても 3 列、横向きでは 5 列', (tester) async {
    List<Widget> dense() => [
          for (var i = 1; i <= 10; i++)
            MoreTile(icon: Icons.star, label: 'ドロップ合わせ$i', dense: true, onTap: () {}),
        ];
    // 幅の上限で決めると 4 列になっていた幅（432 の電話のダイアログの中身 = 360）
    for (final width in [300.0, 360.0]) {
      await pump(
          tester,
          SizedBox(width: width, child: MoreTileGrid(dense: true, tiles: dense())),
          size: const Size(400, 800));
      final t1 = tileRect(tester, 'ドロップ合わせ1');
      final t3 = tileRect(tester, 'ドロップ合わせ3');
      final t4 = tileRect(tester, 'ドロップ合わせ4');
      expect(t3.top, t1.top, reason: '$width');
      expect(t4.top, greaterThan(t1.bottom), reason: '$width');
      expect(t1.width / t1.height, closeTo(MoreTileGrid.denseAspect, 0.02));
      expect(tester.takeException(), isNull, reason: '7 文字のラベルが溢れない');
    }
    await pump(
        tester,
        SizedBox(width: 560, child: MoreTileGrid(dense: true, tiles: dense())),
        size: const Size(800, 360));
    final t1 = tileRect(tester, 'ドロップ合わせ1');
    final t5 = tileRect(tester, 'ドロップ合わせ5');
    final t6 = tileRect(tester, 'ドロップ合わせ6');
    expect(t5.top, t1.top);
    expect(t6.top, greaterThan(t1.bottom));
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
