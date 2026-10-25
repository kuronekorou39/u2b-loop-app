import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/settings/dj_mix_settings_screen.dart';
import 'package:u2b_loop_app/screens/settings_screen.dart';
import 'package:u2b_loop_app/widgets/settings/settings_parts.dart';

/// 設定画面を実際に描画して、トップの並び・各ページへの遷移・値の保存を確認する。
/// トップはスクロール無しで収まる数だけ置き、残りは各ページ（DJ ミックス など）にある
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('u2b_settings_test');
    Hive.init(tempDir.path);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(PlaylistAdapter());
    Hive.registerAdapter(TagAdapter());
    // ファイルではなくメモリ上の box を使う。
    // testWidgets の疑似非同期ゾーン内ではファイル書き込みが完了しないため、
    // ファイル box だと画面操作で書いた値が残り Hive.close() が永久に待ってしまう
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Playlist>(AppBoxes.playlistsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    PackageInfo.setMockInitialValues(
      appName: 'U2B Loop',
      packageName: 'com.u2bloop.u2b_loop_app',
      version: '9.9.9',
      buildNumber: '',
      buildSignature: '',
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: page),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('トップは 7 行で、スクロールせずに全部見える', (tester) async {
    await pumpPage(tester, const SettingsScreen());

    const order = [
      'ダークモード', 'DJ ミックス', '早送り・巻き戻し', 'オフライン保存',
      'バックアップ', 'アップデートを確認', '詳細設定',
    ];
    final ys = [for (final t in order) tester.getTopLeft(find.text(t)).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]),
          reason: '「${order[i]}」が「${order[i - 1]}」より上にある');
    }
    // 最後の行が画面（2280/2.5 = 912）に収まっている
    expect(tester.getBottomLeft(find.text('詳細設定')).dy, lessThan(912));
    // 行数は 7（ふだん触らないものはトップに出さない）
    expect(find.byType(SettingsRow), findsNWidgets(7));
    expect(find.text('クロスフェード'), findsNothing);
    expect(find.text('すべてのデータを削除'), findsNothing);
  });

  testWidgets('スキップ秒数をトップから変えられる', (tester) async {
    await pumpPage(tester, const SettingsScreen());

    expect(find.text('5秒'), findsOneWidget); // 既定値（説明文）
    await tester.tap(find.text('早送り・巻き戻し'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10秒'));
    await tester.pumpAndSettle();

    expect(find.text('10秒'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.seekStep), 10,
        reason: '再生画面と同じ設定値に保存されること');
  });

  testWidgets('DJ ミックスの行から DJ ミックスのページへ', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.text('クロスフェード オフ'), findsOneWidget);
    await tester.tap(find.text('DJ ミックス'));
    await tester.pumpAndSettle();
    expect(find.byType(DjMixSettingsScreen), findsOneWidget);
    expect(find.text('クロスフェード'), findsOneWidget);
    expect(find.text('つなぎ方'), findsOneWidget);
  });

  testWidgets('クロスフェード秒数を DJ ミックスのページで変えられる', (tester) async {
    await pumpPage(tester, const DjMixSettingsScreen());

    expect(find.text('オフ'), findsOneWidget); // 既定値
    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8拍'));
    await tester.pumpAndSettle();

    expect(find.text('8拍'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8,
        reason: 'PlaylistEngine が読む設定値に保存されること');
  });

  testWidgets('クロスフェード中の設定は、クロスフェードがオンのときだけ触れる', (tester) async {
    await pumpPage(tester, const DjMixSettingsScreen());
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8,
        reason: '前のテストでオンにした値を引き継ぐ（メモリ box は setUpAll で1回だけ開く）');

    Switch switchOf(String title) => tester.widget<Switch>(find.descendant(
        of: find.widgetWithText(SettingsSwitchRow, title),
        matching: find.byType(Switch)));

    // 既定はおまかせ。手動の項目はおまかせを切ったときだけ
    expect(switchOf('おまかせ').value, isTrue);
    expect(switchOf('テンポ合わせ').onChanged, isNull);
    await tester.tap(find.text('おまかせ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);

    expect(switchOf('テンポ合わせ').onChanged, isNotNull);
    await tester.tap(find.text('テンポ合わせ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), false,
        reason: '既定オンなので1回タップでオフになり、PlaylistEngine が読む値に保存される');

    await tester.tap(find.text('ドロップに合わせる'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.mixPointAlign), false);

    // ベーススワップは既定オン
    expect(switchOf('ベーススワップ').value, isTrue);
    await tester.tap(find.text('ベーススワップ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.bassSwap), false);

    // つなぎ方と演出はダイアログで選ぶ
    await tester.tap(find.text('つなぎ方'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('次曲先行'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');
    expect(find.text('次曲先行'), findsOneWidget);

    // 演出の既定はフィルタースイープ
    expect(find.text('フィルタースイープ'), findsOneWidget);
    await tester.tap(find.text('切り替えの演出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブレーキ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'brake');

    // クロスフェードをオフにすると触れなくなる
    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('オフ'));
    await tester.pumpAndSettle();
    expect(switchOf('テンポ合わせ').onChanged, isNull);
    expect(switchOf('ドロップに合わせる').onChanged, isNull);
    expect(switchOf('ベーススワップ').onChanged, isNull);
    expect(switchOf('拍合わせ').onChanged, isNull);
    expect(switchOf('入り口を選ぶ').onChanged, isNull);
    expect(find.text('クロスフェードをオンにすると使えます'), findsNWidgets(10),
        reason: '効果音のタイミング・入り口を選ぶの行が増えた');
  });

  testWidgets('トップの DJ ミックスの行に今の設定が要約される', (tester) async {
    AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 16);
    // 前のテストでオフにしたベーススワップを戻す（オンのときだけ要約に出る）
    AppBoxes.settings.put(SettingsKeys.bassSwap, true);
    await pumpPage(tester, const SettingsScreen());
    expect(find.textContaining('クロスフェード 16拍'), findsOneWidget);
    expect(find.textContaining('次曲先行'), findsOneWidget);
    expect(find.textContaining('ベーススワップ'), findsOneWidget);
    expect(find.textContaining('ブレーキ'), findsOneWidget);
  });

  testWidgets('バージョンが表示される', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.text('v9.9.9'), findsOneWidget);
  });
}
