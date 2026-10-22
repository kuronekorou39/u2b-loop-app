import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/first_verse_sheet.dart';

/// 「1番」長押しのシート: 波形を押して終わりを直し、覚える / 自動に戻す。探す範囲は全曲共通で残る
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());
  setUp(() => AppBoxes.settings.clear());

  Future<List<FirstVerseResult?>> open(WidgetTester tester,
      {int? manualEndMs}) async {
    final results = <FirstVerseResult?>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(await FirstVerseSheet.show(
                context,
                title: '曲',
                waveform: List.filled(400, 0.5),
                durationMs: 300000,
                startMs: 0,
                manualEndMs: manualEndMs,
                positionMs: 120000,
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('自動のままでは覚えられず、動かすと覚えられる', (tester) async {
    final results = await open(tester);
    expect(find.text('自動'), findsOneWidget);
    final save = find.widgetWithText(FilledButton, 'この範囲で覚える');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '自動に戻す')).onPressed,
        isNull);
    await tester.tap(find.text('今の位置'));
    await tester.pump();
    expect(find.text('0:00 〜 2:00'), findsOneWidget);
    await tester.tap(find.text('+1秒'));
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect((results.single as FirstVerseSave).endMs, 121000);
  });

  testWidgets('スマホの幅（360）でもはみ出さない', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, manualEndMs: 90000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手で直した曲は「自動に戻す」を選べる', (tester) async {
    final results = await open(tester, manualEndMs: 90000);
    expect(find.text('手で直した範囲'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '自動に戻す'));
    await tester.pumpAndSettle();
    expect(results.single, isA<FirstVerseReset>());
  });

  test('探す範囲は保存され、終わりが始まり以下なら受け付けない', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(verseSearchRangeProvider), VerseRangeNotifier.defaultRange);
    c.read(verseSearchRangeProvider.notifier).value = (startSec: 60, endSec: 150);
    c.read(verseSearchRangeProvider.notifier).value = (startSec: 90, endSec: 90);
    expect(c.read(verseSearchRangeProvider), (startSec: 60, endSec: 150));
    final again = ProviderContainer();
    addTearDown(again.dispose);
    expect(again.read(verseSearchRangeProvider), (startSec: 60, endSec: 150));
    expect(VerseRangeNotifier.label((startSec: 50, endSec: 150)), '50秒〜2分30秒');
  });
}
