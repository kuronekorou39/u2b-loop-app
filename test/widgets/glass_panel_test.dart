import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/glass_provider.dart';
import 'package:u2b_loop_app/widgets/glass_panel.dart';

/// ガラス板: 設定のぼかしオン/オフで BackdropFilter の有無が切り替わること、
/// ピルがタップに反応することを固定する
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });

  tearDownAll(() => Hive.close());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    ));
  }

  testWidgets('既定ではぼかしあり', (tester) async {
    await pump(tester, const GlassPanel(child: SizedBox(width: 100, height: 50)));
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('scrim は白の層とは別に敷かれる（gradient に消されない）', (tester) async {
    await pump(
        tester,
        const GlassPanel(
            blur: false,
            scrim: Colors.black,
            child: SizedBox(width: 100, height: 50)));
    final box = tester.widget<ColoredBox>(find.descendant(
        of: find.byType(GlassPanel), matching: find.byType(ColoredBox)));
    expect(box.color, Colors.black);
  });

  testWidgets('blur: false ならぼかしなし', (tester) async {
    await pump(tester,
        const GlassPanel(blur: false, child: SizedBox(width: 100, height: 50)));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('設定でぼかしを切るとなくなる', (tester) async {
    await pump(tester, const GlassPanel(child: SizedBox(width: 100, height: 50)));
    final container = ProviderScope.containerOf(
        tester.element(find.byType(GlassPanel)));
    container.read(glassBlurProvider.notifier).value = false;
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(AppBoxes.settings.get(SettingsKeys.glassBlur), isFalse);
    container.read(glassBlurProvider.notifier).value = true;
  });

  testWidgets('ピルはタップできる', (tester) async {
    var taps = 0;
    await pump(
        tester, GlassPill(onTap: () => taps++, child: const Text('一覧')));
    await tester.tap(find.text('一覧'));
    expect(taps, 1);
    // ぼかすのは板だけ。ピルは半透明の面のみ
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
