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
import 'package:u2b_loop_app/screens/settings_screen.dart';

/// 設定画面を実際に描画して、セクションの並び・描画エラーの有無を確認する。
/// （見た目の整理で並びを変えたので、誤って順番が崩れたりレイアウト例外が
///   出たりしないことを固定しておく）
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

  Future<void> pumpSettings(WidgetTester tester) async {
    // 縦長の画面で全セクションが収まるようにする（項目が増えたら伸ばす）
    tester.view.physicalSize = const Size(1080, 5200);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('セクションが決めた順に並ぶ', (tester) async {
    await pumpSettings(tester);

    const order = ['表示', '再生', 'ストレージ', 'バックアップ', 'アプリ情報', '危険な操作', '開発者向け'];
    final ys = [
      for (final title in order) tester.getTopLeft(find.text(title)).dy,
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]),
          reason: '「${order[i]}」が「${order[i - 1]}」より上にある');
    }
  });

  testWidgets('危険な操作は通常の操作より下にまとまっている', (tester) async {
    await pumpSettings(tester);

    final dangerHeader = tester.getTopLeft(find.text('危険な操作')).dy;
    for (final normal in ['バックアップを書き出す', 'バックアップから復元', 'アップデートを確認']) {
      expect(tester.getTopLeft(find.text(normal)).dy, lessThan(dangerHeader),
          reason: '「$normal」が危険な操作より下にある');
    }
    for (final danger in ['オフライン動画をすべて削除', 'すべてのデータを削除']) {
      expect(tester.getTopLeft(find.text(danger)).dy, greaterThan(dangerHeader),
          reason: '「$danger」が危険な操作セクションの外にある');
    }
  });

  testWidgets('開発者向けは畳まれていて、開くと中身が出る', (tester) async {
    await pumpSettings(tester);

    expect(find.text('パフォーマンスオーバーレイ'), findsNothing);
    await tester.tap(find.text('開発者向け'));
    await tester.pumpAndSettle();
    expect(find.text('パフォーマンスオーバーレイ'), findsOneWidget);
  });

  testWidgets('スキップ秒数を設定画面から変えられる', (tester) async {
    await pumpSettings(tester);

    expect(find.text('5秒'), findsOneWidget); // 既定値
    await tester.tap(find.text('早送り・巻き戻しの秒数'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10秒'));
    await tester.pumpAndSettle();

    expect(find.text('10秒'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.seekStep), 10,
        reason: '再生画面と同じ設定値に保存されること');
  });

  testWidgets('クロスフェード秒数を設定画面から変えられる', (tester) async {
    await pumpSettings(tester);

    expect(find.text('オフ'), findsOneWidget); // 既定値
    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4秒'));
    await tester.pumpAndSettle();

    expect(find.text('4秒'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeSeconds), 4,
        reason: 'PlaylistEngine が読む設定値に保存されること');
  });

  testWidgets('テンポ合わせはクロスフェードがオンのときだけ切り替えられる', (tester) async {
    await pumpSettings(tester);

    final tile = find.widgetWithText(SwitchListTile, 'テンポ合わせ');
    expect(tile, findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeSeconds), 4,
        reason: '前のテストでオンにした値を引き継ぐ（メモリ box は setUpAll で1回だけ開く）');
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNotNull);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), false,
        reason: '既定オンなので1回タップでオフになり、PlaylistEngine が読む値に保存される');

    // 「ドロップに合わせる」も同じ条件（既定オン）
    final align = find.widgetWithText(SwitchListTile, 'ドロップに合わせる');
    expect(align, findsOneWidget);
    expect(tester.widget<SwitchListTile>(align).onChanged, isNotNull);
    await tester.ensureVisible(align);
    await tester.tap(align);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.mixPointAlign), false);

    // ベーススワップは既定オフ（実験的）
    final bass = find.widgetWithText(SwitchListTile, 'ベーススワップ（実験的）');
    expect(bass, findsOneWidget);
    expect(tester.widget<SwitchListTile>(bass).value, isFalse);
    await tester.ensureVisible(bass);
    await tester.tap(bass);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.bassSwap), true);

    // クロスフェードをオフにすると触れなくなる
    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('オフ'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(align).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(bass).onChanged, isNull);
  });

  testWidgets('つなぎ方はクロスフェードがオンのときだけ選べて、選ぶと保存される', (tester) async {
    await pumpSettings(tester);
    // 前のテストでクロスフェードをオフにしているので触れない
    final tile = find.widgetWithText(ListTile, 'つなぎ方');
    expect(tile, findsOneWidget);
    expect(tester.widget<ListTile>(tile).enabled, isFalse);

    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4秒'));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(tile).enabled, isTrue);

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('次曲先行'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');
    expect(find.textContaining('次曲先行:'), findsOneWidget);

    // 切り替えの演出も同じ形
    final effect = find.widgetWithText(ListTile, '切り替えの演出（実験的）');
    expect(tester.widget<ListTile>(effect).enabled, isTrue);
    await tester.ensureVisible(effect);
    await tester.tap(effect);
    await tester.pumpAndSettle();
    await tester.tap(find.text('エコーアウト'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'echoOut');
  });

  testWidgets('バージョンが表示される', (tester) async {
    await pumpSettings(tester);
    expect(find.text('v9.9.9'), findsOneWidget);
  });
}
