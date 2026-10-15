import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/glass_scaffold.dart';

/// ガラス風の土台。本文の上端は AppBar の下端から始めたいが、State の context から
/// 取った MediaQuery の padding には AppBar の高さが入らない（曲を選択の画面で
/// 検索欄が AppBar の裏に隠れていた）。bodyBuilder の context なら入ることを確かめる
void main() {
  testWidgets('bodyBuilder の context の padding.top には AppBar の高さが入る',
      (tester) async {
    double? outerTop;
    double? innerTop;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (outer) {
        outerTop = MediaQuery.paddingOf(outer).top;
        return GlassScaffold(
          title: const Text('t'),
          bodyBuilder: (inner) {
            innerTop = MediaQuery.paddingOf(inner).top;
            return const SizedBox.shrink();
          },
        );
      }),
    ));
    expect(innerTop, isNotNull);
    expect(innerTop! - outerTop!, greaterThanOrEqualTo(kToolbarHeight));
  });

  testWidgets('body と bodyBuilder は片方だけ', (tester) async {
    expect(
      () => GlassScaffold(
          body: const SizedBox(), bodyBuilder: (_) => const SizedBox()),
      throwsAssertionError,
    );
    // ignore: prefer_const_constructors
    expect(() => GlassScaffold(), throwsAssertionError);
  });

  testWidgets('toolbarHeight で AppBar を低くできる（ホームの横向き）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: GlassScaffold(
          toolbarHeight: 44, title: Text('t'), body: SizedBox.shrink()),
    ));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.toolbarHeight, 44);
    expect(appBar.backgroundColor, Colors.transparent);
  });
}
