import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/dj_mix_controls.dart';
import 'package:u2b_loop_app/widgets/player/dj_mix_sheet.dart';

/// 再生画面の「DJ ミックス」ポップアップ: 中身は設定の DJ ミックスのページと同じ
/// （同じ部品 DjMixControls）。設定値をその場で変えられること、縦でも横向きの電話でも
/// スクロールせずに全部に届くこと、横はページと同じ左右 2 列
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

  /// ボタンが押せるか（クロスフェードがオフの間は押せない）
  bool enabledOf(WidgetTester tester, String label) =>
      tester
          .widget<InkWell>(find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first)
          .onTap !=
      null;

  /// ボタンの下に出る今の値（名前の下の 2 行目）
  bool showsValue(WidgetTester tester, String label, String value) => find
      .descendant(
          of: find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first,
          matching: find.text(value))
      .evaluate()
      .isNotEmpty;

  /// 丸いボタンを押して候補を選ぶ（候補のメニューはボタンの下。今の値と同じ文字は後ろ）
  Future<void> pick(WidgetTester tester, String button, String option) async {
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('中身は設定のページと同じ。クロスフェードがオフの間は他の項目に触れない', (tester) async {
    await pumpSheet(tester);
    expect(find.byType(Dialog), findsOneWidget, reason: '縦でも真ん中のポップアップ');
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(DjMixControls), findsOneWidget);

    expect(tester.widget<Slider>(find.byType(Slider)).value, 0, reason: '既定はオフ');
    expect(find.text('オフ'), findsOneWidget, reason: '長さの値だけ');
    for (final label in ['つなぎ方', 'ドロップ', 'テンポ', '入れ替え', '演出', '効果音']) {
      expect(enabledOf(tester, label), isFalse, reason: label);
    }
    // 表示の群はクロスフェードに関係なく触れる
    expect(enabledOf(tester, '拍の線'), isTrue);
    // 既定: 帯域の入れ替えは低音だけ / 演出はフィルタースイープ
    expect(showsValue(tester, '入れ替え', '低音'), isTrue);
    expect(showsValue(tester, '演出', 'スイープ'), isTrue);
  });

  testWidgets('長さ・つなぎ方・入れ替え・演出を変えると PlaylistEngine が読む設定値が変わる',
      (tester) async {
    await pumpSheet(tester);

    tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8);
    expect(find.text('8拍'), findsOneWidget);
    // 既定はおまかせ。手動の項目もおまかせ中に触れ、変えるとおまかせが切れてカスタムに
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(enabledOf(tester, 'つなぎ方'), isTrue);
    await pick(tester, 'つなぎ方', '次曲先行');
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    // 帯域の入れ替えは なし / 低音 / 高・中・低 から選ぶ
    await pick(tester, '入れ替え', '高・中・低');
    expect(AppBoxes.settings.get(SettingsKeys.bandSwap), 'three');
    await pick(tester, '入れ替え', 'なし');
    expect(AppBoxes.settings.get(SettingsKeys.bandSwap), 'none');

    // 曲の音から作る演出も選べる
    await pick(tester, '演出', 'エコーアウト');
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'echoTail');
    await pick(tester, '演出', 'ブレーキ');
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'brake');

    // オンオフは上下のスイッチ（押すと反転）
    final before = AppBoxes.settings
        .get(SettingsKeys.tempoMatch, defaultValue: true) as bool;
    await tester.tap(find.text('テンポ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), !before);
  });

  testWidgets('効果音の音量と、効果音のタイミング（10ms 刻み、押してもメニューは閉じない）',
      (tester) async {
    await pumpSheet(tester);
    // 前のテストでクロスフェードはオン
    expect(showsValue(tester, '効果音', 'ふつう'), isTrue);
    await pick(tester, '効果音', '大きめ');
    expect(AppBoxes.settings.get(SettingsKeys.sfxLevelDb), 0);

    await tester.tap(find.text('タイミング'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('10ms 遅く'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('10ms 遅く'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.sfxOffsetMs), 20);
  });

  for (final size in const [
    Size(360, 640), // 小さい縦の電話
    Size(412, 915), // 縦の電話
    Size(800, 360), // 小さい横向きの電話
    Size(915, 412), // 横向きの電話
  ]) {
    testWidgets('$size でもスクロールせずに全部に届く。横はページと同じ左右 2 列', (tester) async {
      await pumpSheet(tester, size: size, dpr: 1);
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      final dialog = tester.getRect(find.byType(Dialog));
      expect(dialog.bottom, lessThanOrEqualTo(size.height));
      for (final label in const [
        '控えめ', 'おまかせ', '1番', 'つなぎ方', 'ドロップ', '出入り口', 'テンポ', '拍合わせ',
        '入れ替え', '演出', '効果音', 'タイミング', '拍の線', '一覧の線', '音量の線',
      ]) {
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
        final r = tester.getRect(find.text(label));
        expect(dialog.contains(r.center), isTrue, reason: label);
      }
      // オンオフは見た目で（「オン」の文字は出さない）
      expect(find.text('オン'), findsNothing);
      final slider = tester.getRect(find.byType(Slider));
      final groups = tester.getRect(find.text('つなぎ'));
      if (size.width > size.height) {
        expect(groups.left, greaterThan(slider.right), reason: '横: 群は右の列');
      } else {
        expect(groups.top, greaterThan(slider.bottom), reason: '縦: 群は下');
      }
    });
  }
}
