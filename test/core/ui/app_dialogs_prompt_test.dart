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
