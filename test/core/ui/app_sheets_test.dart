import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/ui/app_sheets.dart';

/// 共通のアクションシート: 見出し・行・選択中の印・無効・補足、
/// 行のタップはシートを閉じてから呼ばれる、件数が多くてもスクロールできる
void main() {
  Future<void> open(WidgetTester tester, List<SheetAction> actions,
      {String? title, String? subtitle, String? note}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => AppSheets.actions(ctx,
              title: title, subtitle: subtitle, note: note, actions: actions),
          child: const Text('開く'),
        ),
      ),
    ));
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
  }

  testWidgets('見出し・行・補足が出て、タップでシートが閉じてから onTap', (tester) async {
    final tapped = <String>[];
    await open(
      tester,
      title: 'サビ',
      subtitle: '3 件',
      note: '補足です',
      [
        const SheetAction.heading('メイン'),
        SheetAction(icon: Icons.edit, label: '名前を変更', onTap: () => tapped.add('rename')),
        SheetAction(
            icon: Icons.delete_outline,
            label: '削除',
            destructive: true,
            onTap: () => tapped.add('delete')),
      ],
    );
    expect(find.text('サビ'), findsOneWidget);
    expect(find.text('3 件'), findsOneWidget);
    expect(find.text('メイン'), findsOneWidget);
    expect(find.text('補足です'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(tapped, ['delete']);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('選択中の行にはチェックが付き、無効の行は押せない', (tester) async {
    final tapped = <String>[];
    await open(tester, [
      SheetAction(label: '日本語', selected: true, onTap: () => tapped.add('ja')),
      SheetAction(label: '英語', enabled: false, onTap: () => tapped.add('en')),
    ]);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('英語'));
    await tester.pumpAndSettle();
    expect(tapped, isEmpty);
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  group('低い画面（横向きの電話）', () {
    /// 画面 800×360、ミニプレイヤーの分（84）が下の padding / viewPadding に足されている
    Future<double?> openProbe(WidgetTester tester,
        {required Size size, required Future<void> Function(BuildContext) show}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (ctx, child) {
          final mq = MediaQuery.of(ctx);
          return MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(bottom: 84),
              viewPadding: mq.viewPadding.copyWith(bottom: 84),
            ),
            child: child!,
          );
        },
        home: Builder(
          builder: (ctx) =>
              TextButton(onPressed: () => show(ctx), child: const Text('開く')),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      final probe = find.byKey(const Key('probe'));
      if (probe.evaluate().isEmpty) return null;
      return MediaQuery.viewPaddingOf(tester.element(probe)).bottom;
    }

    /// 実際のシートと同じ組み方（SafeArea + 見出し + 流れる一覧）。
    /// probe は SafeArea の外側（SafeArea は中の viewPadding を padding の分だけ減らす）
    Widget probeSheet() => KeyedSubtree(
          key: const Key('probe'),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(title: Text('タグを選択')),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (var i = 1; i <= 12; i++) ListTile(title: Text('タグ $i')),
                ]),
              ),
            ]),
          ),
        );

    testWidgets('真ん中のダイアログで出て、中では下の余白を二重に取らない', (tester) async {
      final vp = await openProbe(tester,
          size: const Size(800, 360),
          show: (ctx) => AppSheets.show<void>(ctx, builder: (_) => probeSheet()));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(vp, 0, reason: 'ダイアログは安全な範囲に置かれるので中は 0');
      // 中身はミニプレイヤーの分（下 84）にかからず、幅は上限まで
      final content = tester.getRect(find.byKey(const Key('probe')));
      expect(content.bottom, lessThanOrEqualTo(360 - 84));
      expect(content.width, AppSheets.dialogMaxWidth);
      // 一覧は入る分だけ見える（360 − 84 の中で見出し + 3 行）
      expect(find.text('タグ 3').hitTestable(), findsOneWidget);
    });

    testWidgets('ふつうの高さなら今までどおり下のシート（下の余白は中身が避ける）', (tester) async {
      final vp = await openProbe(tester,
          size: const Size(400, 800),
          show: (ctx) => AppSheets.show<void>(ctx, builder: (_) => probeSheet()));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(vp, 84);
    });

    testWidgets('アクションシートも低い画面ではダイアログで、行のタップで閉じる', (tester) async {
      final tapped = <String>[];
      await openProbe(tester,
          size: const Size(800, 360),
          show: (ctx) => AppSheets.actions(ctx, title: '曲', actions: [
                for (var i = 1; i <= 10; i++)
                  SheetAction(label: '項目 $i', onTap: () => tapped.add('$i')),
              ]));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('曲'), findsOneWidget);
      await tester.tap(find.text('項目 2'));
      await tester.pumpAndSettle();
      expect(tapped, ['2']);
      expect(find.byType(Dialog), findsNothing);
    });
  });

  testWidgets('件数が多いときは中で流れて最後まで届く', (tester) async {
    await open(tester, [
      for (var i = 1; i <= 40; i++) SheetAction(label: '項目 $i', onTap: () {}),
    ]);
    // 行は全部作られるので「画面内で押せるか」で見る
    expect(find.text('項目 40').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(find.text('項目 40'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('項目 40').hitTestable(), findsOneWidget);
  });
}
