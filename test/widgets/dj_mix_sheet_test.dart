import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/dj_mix_sheet.dart';
import 'package:u2b_loop_app/widgets/player/more_tile.dart';

/// 再生画面の「DJ ミックス」ポップアップ: 設定画面と同じ値をその場で変えられること、
/// 縦でも横向きの電話でもスクロールせずに全部に届くこと
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

  Future<void> pumpSheet(WidgetTester tester,
      {Size size = const Size(1080, 2280), double dpr = 2.5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
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

  MoreTile tileOf(WidgetTester tester, String label) =>
      tester.widget<MoreTile>(find.ancestor(
          of: find.text(label), matching: find.byType(MoreTile)));

  /// 選ぶタイルを押して候補を選ぶ
  Future<void> pick(WidgetTester tester, String tile, String option) async {
    await tester.tap(find.text(tile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option));
    await tester.pumpAndSettle();
  }

  testWidgets('クロスフェードがオフの間は他の項目に触れない（状態は薄く残る）', (tester) async {
    await pumpSheet(tester);
    expect(find.byType(Dialog), findsOneWidget, reason: '縦でも真ん中のポップアップ');
    expect(find.byType(BottomSheet), findsNothing);

    expect(tileOf(tester, 'クロスフェード').value, 'オフ');
    expect(tileOf(tester, 'つなぎ方').enabled, isFalse);
    expect(tileOf(tester, '演出').enabled, isFalse);
    expect(tileOf(tester, 'ベーススワップ').enabled, isFalse);
    // 既定: ベーススワップ オン / 演出はフィルタースイープ
    expect(tileOf(tester, 'ベーススワップ').active, isTrue);
    expect(tileOf(tester, '演出').value, 'フィルタースイープ');
  });

  testWidgets('拍数を選ぶと PlaylistEngine が読む設定値が変わる', (tester) async {
    await pumpSheet(tester);

    await pick(tester, 'クロスフェード', '8拍');
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8);
    expect(tileOf(tester, 'クロスフェード').value, '8拍');
    // 既定はおまかせ。手動の項目はおまかせを切ると触れる
    expect(tileOf(tester, 'おまかせ').active, isTrue);
    expect(tileOf(tester, 'つなぎ方').enabled, isFalse);
    await tester.tap(find.text('おまかせ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);
    expect(tileOf(tester, 'つなぎ方').enabled, isTrue);

    await pick(tester, 'つなぎ方', '次曲先行');
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');

    await tester.tap(find.text('ベーススワップ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.bassSwap), false);
    expect(tileOf(tester, 'ベーススワップ').active, isFalse);

    await pick(tester, '演出', 'ブレーキ');
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'brake');
  });

  testWidgets('効果音の音量は、効果音を使う演出を選んだときだけ触れる', (tester) async {
    await pumpSheet(tester);
    // 前のテストでクロスフェードはオン、演出はブレーキ（効果音は使わない）
    expect(tileOf(tester, '効果音').value, 'ふつう');
    expect(tileOf(tester, '効果音').enabled, isFalse);

    await pick(tester, '演出', 'ライザー＋インパクト');
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'riserImpact');
    expect(tileOf(tester, '効果音').enabled, isTrue);

    await pick(tester, '効果音', '大きめ');
    expect(AppBoxes.settings.get(SettingsKeys.sfxLevelDb), 0);
    expect(tileOf(tester, '効果音').value, '大きめ');
  });

  testWidgets('効果音のタイミングは「−」「+」で 10ms 刻み（効果音を使う演出のときだけ）', (tester) async {
    await pumpSheet(tester);
    // 前のテストで演出はライザー＋インパクト
    expect(find.text('0ms'), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('+10ms'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.sfxOffsetMs), 10);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.remove));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('−10ms'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.sfxOffsetMs), -10);

    // 効果音を使わない演出にすると触れない
    await pick(tester, '演出', 'ブレーキ');
    final add = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add));
    expect(add.onPressed, isNull);
  });

  testWidgets('横向きの電話（800×360）でもスクロールせずに全部に届く', (tester) async {
    await pumpSheet(tester, size: const Size(800, 360), dpr: 1);
    for (final label in ['控えめ', 'クロスフェード', 'おまかせ', 'ベーススワップ', '効果音', '効果音のずれ']) {
      expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
    }
    final dialog = tester.getRect(find.byType(Dialog));
    expect(dialog.bottom, lessThanOrEqualTo(360));
  });

  testWidgets('縦でもスクロールせずに全部に届く', (tester) async {
    await pumpSheet(tester, size: const Size(360, 640), dpr: 1);
    for (final label in ['控えめ', 'クロスフェード', 'ベーススワップ', '効果音', '効果音のずれ']) {
      expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
    }
  });
}
