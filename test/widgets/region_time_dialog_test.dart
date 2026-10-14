import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/loop/region_time_dialog.dart';

/// 区間の AB 時間ダイアログ: 読めない値と A ≧ B は保存できず、その場でエラーが出る。
/// 以前は検証が無く、数字でない値を入れると点が黙って消えていた
void main() {
  /// ダイアログを開いて、閉じた後に戻り値を取る関数を返す
  Future<Future<({int? aMs, int? bMs})?> Function()> open(
    WidgetTester tester, {
    int? aMs,
    int? bMs,
  }) async {
    ({int? aMs, int? bMs})? result;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await showRegionTimeDialog(ctx,
                title: 'サビ の AB 時間', aMs: aMs, bMs: bMs);
            closed = true;
          },
          child: const Text('開く'),
        ),
      ),
    ));
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    return () async {
      await tester.pumpAndSettle();
      expect(closed, isTrue, reason: 'ダイアログが閉じていない');
      return result;
    };
  }

  Finder field(String label) => find.ancestor(
      of: find.text(label), matching: find.byType(TextField));

  final saveButton = find.widgetWithText(TextButton, '保存');
  const parseError = '「1:23.5」か秒数で入力してください';

  testWidgets('初期値は M:SS.mmm で入り、保存で ms が返る', (tester) async {
    final finish = await open(tester, aMs: 1500, bMs: 65000);
    expect(find.text('0:01.500'), findsOneWidget);
    expect(find.text('1:05.000'), findsOneWidget);

    await tester.enterText(field('A'), '0:02');
    await tester.enterText(field('B'), '70.25');
    await tester.pump();
    await tester.tap(saveButton);
    expect(await finish(), (aMs: 2000, bMs: 70250));
  });

  testWidgets('読めない値はエラーが出て保存できない', (tester) async {
    await open(tester);
    await tester.enterText(field('A'), 'abc');
    await tester.pump();
    expect(find.text(parseError), findsOneWidget);
    expect(tester.widget<TextButton>(saveButton).onPressed, isNull);

    // 直せば保存できる
    await tester.enterText(field('A'), '1:00');
    await tester.pump();
    expect(find.text(parseError), findsNothing);
    expect(tester.widget<TextButton>(saveButton).onPressed, isNotNull);
  });

  testWidgets('A ≧ B はエラーが出て保存できない', (tester) async {
    await open(tester);
    await tester.enterText(field('A'), '1:00');
    await tester.enterText(field('B'), '0:30');
    await tester.pump();
    expect(find.text('B は A より後にしてください'), findsOneWidget);
    expect(tester.widget<TextButton>(saveButton).onPressed, isNull);
  });

  testWidgets('空欄は未設定（null）として返る', (tester) async {
    final finish = await open(tester, aMs: 1000, bMs: 2000);
    await tester.enterText(field('B'), '');
    await tester.pump();
    await tester.tap(saveButton);
    expect(await finish(), (aMs: 1000, bMs: null));
  });

  testWidgets('キャンセルは null', (tester) async {
    final finish = await open(tester);
    await tester.tap(find.text('キャンセル'));
    expect(await finish(), isNull);
  });
}
