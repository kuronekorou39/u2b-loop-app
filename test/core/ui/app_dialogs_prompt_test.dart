import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/ui/app_dialogs.dart';

/// 入力ダイアログ: 上限を超えた初期値でも、編集中に末尾をまとめて切り詰めない。
/// 超えている間は OK を押せず、上限内に収めれば確定できる
void main() {
  Future<Future<String?>> open(WidgetTester tester, String initial) async {
    late Future<String?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => result = AppDialogs.prompt(context,
                title: '曲名', initialValue: initial, maxLength: 10),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  TextButton okButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'OK'));

  testWidgets('上限超えの初期値を 1 文字消しても残りは切られない', (tester) async {
    await open(tester, 'a' * 15);
    await tester.enterText(find.byType(TextField), 'a' * 14);
    await tester.pump();
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'a' * 14);
    expect(okButton(tester).onPressed, isNull);
    expect(find.text('14 / 10 文字'), findsOneWidget);
  });

  testWidgets('低い画面でキーボードが出ていても、入力欄とボタンが押せる場所に出る', (tester) async {
    // 横向きの電話（800×360）でキーボードが 220 出ている
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.reset);
    await open(tester, 'abc');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom, lessThanOrEqualTo(360 - 220),
        reason: '入力欄はキーボードにかからない');
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.text('OK').hitTestable(), findsOneWidget);
    // 見出しとボタンは同じ行
    expect(tester.getCenter(find.text('OK')).dy,
        closeTo(tester.getCenter(find.text('曲名')).dy, 1));
  });

  testWidgets('上限内に収めれば OK で確定できる', (tester) async {
    final result = await open(tester, 'a' * 15);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(okButton(tester).onPressed, isNotNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await result, 'abc');
  });
}
