import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/providers/glass_provider.dart';
import 'package:u2b_loop_app/widgets/glass_panel.dart';
import 'package:u2b_loop_app/widgets/glass_surface.dart';
import 'package:u2b_loop_app/widgets/item_thumbnail.dart';

/// ガラス板: 設定のぼかしオン/オフで BackdropFilter の有無が切り替わること、
/// ピルがタップに反応すること、ライトテーマで面が地より明るい白になることを固定する
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });

  tearDownAll(() => Hive.close());

  Future<void> pump(WidgetTester tester, Widget child, {ThemeData? theme}) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(theme: theme, home: Scaffold(body: Center(child: child))),
    ));
  }

  /// 面の塗り（左上の色）
  Color topLeftOf(WidgetTester tester, Finder of) {
    final decorated = tester
        .widgetList<Container>(find.descendant(of: of, matching: find.byType(Container)))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.gradient != null);
    return (decorated.gradient! as LinearGradient).colors.first;
  }

  group('ライトテーマ', () {
    testWidgets('地を敷かない板は、明るい地より明らかに明るい白の板にする', (tester) async {
      await pump(tester, const GlassPanel(child: SizedBox(width: 100, height: 50)),
          theme: AppTheme.light);
      final c = topLeftOf(tester, find.byType(GlassPanel));
      expect(c.r, 1);
      expect(c.a, greaterThan(0.5));
    });

    testWidgets('地（scrim）を敷く板は白を薄いまま（全画面の暗い板の白い字が読めるように）',
        (tester) async {
      await pump(
          tester,
          GlassPanel(
              blur: false,
              scrim: Colors.black.withValues(alpha: 0.5),
              child: const SizedBox(width: 100, height: 50)),
          theme: AppTheme.light);
      expect(topLeftOf(tester, find.byType(GlassPanel)).a, lessThan(0.2));
    });

    testWidgets('一覧・設定の面も白（黒を重ねたくすんだ灰色にしない）。色付きの面は色が残る',
        (tester) async {
      Future<Color> fillOf(Color? tint) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
              body: GlassSurface(tint: tint, child: const SizedBox(width: 100, height: 50))),
        ));
        final ink = tester.widget<Ink>(find.byType(Ink));
        return ((ink.decoration! as BoxDecoration).gradient! as LinearGradient)
            .colors
            .first;
      }

      final plain = await fillOf(null);
      expect(plain.r, 1);
      expect(plain.g, 1);
      expect(plain.a, greaterThan(0.5));
      final tinted = await fillOf(Colors.orange.withValues(alpha: 0.3));
      expect(tinted.b, lessThan(plain.b), reason: '橙が混ざる');
    });

    testWidgets('サムネの無い曲の地はライトで白にしない（白い面の上で枠ごと消えない）', (tester) async {
      late Color color;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Builder(builder: (context) {
          color = ItemThumbnail.placeholderColor(context);
          return const SizedBox();
        }),
      ));
      expect(color.a, lessThan(0.5), reason: '下の白い面より少し暗い薄い灰色');
    });

    test('線の色: ダークは白、ライトは文字と同じ濃紺', () {
      expect(AppTheme.ink(Brightness.dark), Colors.white);
      expect(AppTheme.ink(Brightness.light), AppTheme.darkBackground);
    });
  });

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
