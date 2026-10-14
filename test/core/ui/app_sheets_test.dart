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
