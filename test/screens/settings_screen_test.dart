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
import 'package:u2b_loop_app/widgets/player/more_tile.dart';
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
    tester.view.physicalSize = const Size(1080, 2700);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: page),
    ));
    await tester.pumpAndSettle();
  }

  const tileLabels = [
    'ダークモード', 'DJ ミックス', 'スキップ秒数', 'オフライン保存',
    'バックアップ', 'アップデート', '詳細設定',
  ];

  /// 画面の大きさ（論理ピクセル）を指定して設定のトップを出し、ボタンの矩形を返す
  Future<List<Rect>> pumpTop(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$size');
    return [
      for (final t in tileLabels)
        tester.getRect(
            find.ancestor(of: find.text(t), matching: find.byType(MoreTile)))
    ];
  }

  testWidgets('トップは四角い大きなボタン 7 つ。縦の電話は 2 列で、矢印は付けない', (tester) async {
    final rects = await pumpTop(tester, const Size(412, 915));
    for (var i = 0; i < rects.length; i++) {
      expect(rects[i].width, closeTo(rects[i].height, 0.5), reason: '正方形');
      expect(rects[i].width, greaterThan(140), reason: 'デカいボタン');
      // 2 列: 偶数番目が左、奇数番目がその右の同じ行
      if (i.isOdd) {
        expect(rects[i].top, rects[i - 1].top);
        expect(rects[i].left, greaterThan(rects[i - 1].right));
      } else if (i > 0) {
        expect(rects[i].top, greaterThan(rects[i - 2].bottom));
        expect(rects[i].left, rects[0].left);
      }
    }
    expect(find.byType(MoreTile), findsNWidgets(7));
    // 矢印は付けない。ふだん触らないものはトップに出さない
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('クロスフェード'), findsNothing);
    expect(find.text('すべてのデータを削除'), findsNothing);
  });

  testWidgets('縦でも横でも、スクロールせずに全部が画面に収まり、端に余白がある', (tester) async {
    for (final size in const [
      Size(412, 915), // 縦の電話
      Size(360, 640), // 小さい縦の電話
      Size(915, 412), // 横向きの電話
      Size(800, 360), // 小さい横向きの電話
      Size(1400, 900), // 広い画面
    ]) {
      final rects = await pumpTop(tester, size);
      expect(find.byType(Scrollable), findsNothing, reason: '$size');
      final left = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final right = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      final bottom = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      // 左右は同じだけ空け、端まで詰めない
      expect(left, greaterThanOrEqualTo(24), reason: '$size');
      expect(left, closeTo(size.width - right, 0.5), reason: '$size');
      // 下も空ける（曲数の行もその中に収まる）
      expect(bottom, lessThanOrEqualTo(size.height - 24), reason: '$size');
      expect(
          tester.getRect(find.textContaining('プレイリスト 0')).bottom,
          lessThanOrEqualTo(size.height - 24),
          reason: '$size');
      // 大きくなりすぎない
      expect(rects.first.width, lessThanOrEqualTo(SettingsScreen.maxTileSide),
          reason: '$size');
      for (final r in rects) {
        expect(r.width, closeTo(r.height, 0.5), reason: '$size');
        expect(r.width, greaterThan(80), reason: '$size');
      }
    }
  });

  test('並べ方: ボタンがいちばん大きくなる列数を選ぶ', () {
    // 縦長は 2 列 × 4 行
    expect(SettingsScreen.gridFor(const Size(360, 700), 7).columns, 2);
    // 横長で低いと 1 行
    expect(SettingsScreen.gridFor(const Size(860, 200), 7).columns, 7);
    // 上限より大きくはしない
    expect(SettingsScreen.gridFor(const Size(2000, 2000), 7).side,
        SettingsScreen.maxTileSide);
  });

  testWidgets('ダークモードはボタンを押すたびに切り替わる', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    MoreTile dark() => tester.widget<MoreTile>(find.ancestor(
        of: find.text('ダークモード'), matching: find.byType(MoreTile)));
    final before = dark().active!;
    await tester.tap(find.text('ダークモード'));
    await tester.pumpAndSettle();
    expect(dark().active, !before);
    await tester.tap(find.text('ダークモード'));
    await tester.pumpAndSettle();
    expect(dark().active, before);
  });

  testWidgets('スキップ秒数をトップから変えられる', (tester) async {
    await pumpPage(tester, const SettingsScreen());

    expect(find.text('5秒'), findsOneWidget); // 既定値（説明文）
    await tester.tap(find.text('スキップ秒数'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10秒'));
    await tester.pumpAndSettle();

    expect(find.text('10秒'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.seekStep), 10,
        reason: '再生画面と同じ設定値に保存されること');
  });

  testWidgets('DJ ミックスの行から DJ ミックスのページへ', (tester) async {
    await pumpPage(tester, const SettingsScreen());
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
    // 行が増えてページが長くなったので、見えるところまで送ってから押す
    await tester.ensureVisible(find.text('切り替えの演出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切り替えの演出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブレーキ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'brake');

    // クロスフェードをオフにすると触れなくなる
    // 演出を選ぶために下へ送ったので、上端の行まで戻す
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('クロスフェード'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('オフ'));
    await tester.pumpAndSettle();
    expect(switchOf('テンポ合わせ').onChanged, isNull);
    expect(switchOf('ドロップに合わせる').onChanged, isNull);
    expect(switchOf('ベーススワップ').onChanged, isNull);
    expect(switchOf('拍合わせ').onChanged, isNull);
    expect(switchOf('出入り口を選ぶ').onChanged, isNull);
    expect(find.text('クロスフェードをオンにすると使えます'), findsNWidgets(10),
        reason: '効果音のタイミング・入り口を選ぶの行が増えた');
  });

  testWidgets('トップの DJ ミックスのボタンに今のクロスフェードが出る', (tester) async {
    AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 16);
    // 前のテストでオフにしたベーススワップを戻す
    AppBoxes.settings.put(SettingsKeys.bassSwap, true);
    await pumpPage(tester, const SettingsScreen());
    expect(
        tester
            .widget<MoreTile>(find.ancestor(
                of: find.text('DJ ミックス'), matching: find.byType(MoreTile)))
            .value,
        '16拍');
  });

  testWidgets('バージョン行を 5 回押すとデバッグモード。詳細設定にデバッグの群が出て、終了で消える',
      (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.textContaining('デバッグ'), findsNothing);

    // ふだんは詳細設定にデバッグの群が無い
    await tester.tap(find.text('詳細設定'));
    await tester.pumpAndSettle();
    expect(find.text('テスト版も受け取る'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('アップデート'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.debugMode), true);

    await tester.tap(find.text('詳細設定'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('デバッグモードを終了'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('テスト版も受け取る'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.betaUpdates), true);

    // 終了すると群が消え、中の設定も切れる
    await tester.tap(find.text('デバッグモードを終了'));
    await tester.pumpAndSettle();
    expect(find.text('テスト版も受け取る'), findsNothing);
    expect(AppBoxes.settings.get(SettingsKeys.debugMode), false);
    expect(AppBoxes.settings.get(SettingsKeys.betaUpdates), false);
  });

  testWidgets('バージョンが表示される', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.text('v9.9.9'), findsOneWidget);
  });
}
