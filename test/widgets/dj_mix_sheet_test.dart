import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/dj_mix_sheet.dart';

/// 再生画面の「DJ ミックス」シート: 設定画面と同じ値をその場で変えられること
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('u2b_dj_sheet_test');
    Hive.init(tempDir.path);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DjMixSheet.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ChoiceChip chipOf(WidgetTester tester, String label) =>
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

  Switch switchOf(WidgetTester tester, String title) =>
      tester.widget<Switch>(find.descendant(
          of: find.widgetWithText(SwitchListTile, title),
          matching: find.byType(Switch)));

  testWidgets('クロスフェードがオフの間は他の項目に触れない', (tester) async {
    await pumpSheet(tester);

    expect(chipOf(tester, 'オフ').selected, isTrue);
    expect(chipOf(tester, '次曲先行').onSelected, isNull);
    expect(chipOf(tester, 'エコーアウト').onSelected, isNull);
    expect(switchOf(tester, 'ベーススワップ').onChanged, isNull);
    // 既定: ベーススワップ オン / 演出はフィルタースイープ
    expect(switchOf(tester, 'ベーススワップ').value, isTrue);
    expect(chipOf(tester, 'フィルタースイープ').selected, isTrue);
  });

  testWidgets('拍数のチップで PlaylistEngine が読む設定値が変わる', (tester) async {
    await pumpSheet(tester);

    await tester.tap(find.text('8拍'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8);
    expect(chipOf(tester, '次曲先行').onSelected, isNotNull);

    await tester.tap(find.text('次曲先行'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');

    await tester.tap(find.text('ベーススワップ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.bassSwap), false);

    await tester.tap(find.text('エコーアウト'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'echoOut');
  });

  testWidgets('効果音の音量は、効果音を使う演出を選んだときだけ触れる', (tester) async {
    await pumpSheet(tester);
    // 前のテストでクロスフェードはオン、演出はエコーアウト
    expect(chipOf(tester, 'ふつう').selected, isTrue);
    expect(chipOf(tester, '大きめ').onSelected, isNull);

    await tester.tap(find.text('ライザー＋インパクト'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'riserImpact');
    expect(chipOf(tester, '大きめ').onSelected, isNotNull);

    await tester.tap(find.text('大きめ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.sfxLevelDb), 0);
    expect(find.text('曲と同じ大きさ'), findsOneWidget);
  });
}
