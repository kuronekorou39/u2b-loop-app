import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/settings/dj_mix_settings_screen.dart';
import 'package:u2b_loop_app/screens/settings_screen.dart';
import 'package:u2b_loop_app/widgets/player/more_tile.dart';

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
    // 縦の電話で「DJ ミックス・表示と再生」「保存データ・バックアップ」の 2 行
    'DJ ミックス', '表示・再生', '保存データ', 'バックアップ',
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

  testWidgets('トップは四角い大きなボタン 4 つ。縦の電話は 2 列で、矢印は付けない', (tester) async {
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
    expect(find.byType(MoreTile), findsNWidgets(4));
    // アップデートはボタンではなく、下の真ん中の札
    final chip = tester.getRect(find.text('  ·  更新を確認'));
    expect(chip.top, greaterThan(rects.last.bottom));
    expect(chip.center.dx, closeTo(412 / 2, 60));
    // スキップ秒数は再生画面の ±N 秒ボタンの長押しで選ぶ（ここには置かない）
    expect(find.textContaining('スキップ'), findsNothing);
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
    // 縦長は 2 列 × 2 行
    expect(SettingsScreen.gridFor(const Size(360, 700), 4).columns, 2);
    // 横長で低いと 1 行
    expect(SettingsScreen.gridFor(const Size(860, 200), 4).columns, 4);
    // 上限より大きくはしない
    expect(SettingsScreen.gridFor(const Size(2000, 2000), 4).side,
        SettingsScreen.maxTileSide);
  });

  testWidgets('ダーク / ライトの切り替えは右上のボタン（ラベルなし）。押すたびに切り替わる',
      (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.text('ダークモード'), findsNothing);
    final before = AppBoxes.settings.get(SettingsKeys.darkMode);
    final button = find.byTooltip('ライトモードにする');
    expect(button, findsOneWidget);
    // 見出しの右上（ボタンの並びより上）
    final rect = tester.getRect(button);
    expect(rect.center.dx, greaterThan(432 * 0.8));
    // 右端に付けすぎない
    expect(rect.right, lessThanOrEqualTo(432 - AppSpacing.lg));
    expect(
        rect.bottom,
        lessThanOrEqualTo(
            tester.getRect(find.byType(MoreTile).first).top));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byTooltip('ダークモードにする'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.darkMode), isNot(before));
    await tester.tap(find.byTooltip('ダークモードにする'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('ライトモードにする'), findsOneWidget);
  });

  testWidgets('横向きの電話では、ボタンが画面の幅をほぼ使う（余白が大きく余らない）', (tester) async {
    final rects = await pumpTop(tester, const Size(915, 412));
    // 1 行に 4 つ
    expect(rects.every((r) => r.top == rects.first.top), isTrue);
    expect(rects.first.left, lessThanOrEqualTo(40));
    expect(rects.last.right, greaterThanOrEqualTo(915 - 40));
  });

  testWidgets('DJ ミックスのボタンから DJ ミックスのページへ', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    await tester.tap(find.text('DJ ミックス'));
    await tester.pumpAndSettle();
    expect(find.byType(DjMixSettingsScreen), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('つなぎ方'), findsOneWidget);
  });

  /// DJ ミックスのページのボタンが押せるか
  bool enabledOf(WidgetTester tester, String label) => tester
          .widget<InkWell>(find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first)
          .onTap !=
      null;

  testWidgets('DJ ミックスは縦でも横でもスクロールせずに全部収まる。横は左右 2 列', (tester) async {
    for (final size in const [
      Size(412, 915), // 縦の電話
      Size(360, 640), // 小さい縦の電話
      Size(915, 412), // 横向きの電話
      Size(800, 360), // 小さい横向きの電話
      Size(1400, 900), // 広い画面
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: DjMixSettingsScreen()),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.byType(Scrollable), findsNothing, reason: '$size');
      for (final label in const [
        'おまかせ', '1番', 'つなぎ方', 'ドロップ', '出入り口', 'テンポ', '拍合わせ', '入れ替え',
        '演出', '効果音', 'タイミング', '拍の線', '一覧の線', '音量の線',
      ]) {
        final r = tester.getRect(find.text(label));
        expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$size $label');
        expect(r.right, lessThanOrEqualTo(size.width), reason: '$size $label');
      }
      // オンオフは見た目で（「オン」「オフ」の文字は出さない）
      expect(find.text('オン'), findsNothing, reason: '$size');
      expect(find.text('オフ'), findsOneWidget, reason: '長さの値だけ');
      final slider = tester.getRect(find.byType(Slider));
      final groups = tester.getRect(find.text('つなぎ'));
      if (size.width > size.height) {
        // 横: 大きいものは左、アイコンの群は右
        expect(groups.left, greaterThan(slider.right), reason: '$size');
      } else {
        expect(groups.top, greaterThan(slider.bottom), reason: '$size');
      }
    }
  });

  testWidgets('クロスフェードの長さはつまみで変える', (tester) async {
    await pumpPage(tester, const DjMixSettingsScreen());
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0, reason: '既定はオフ');
    // オフの間は他は触れない
    expect(enabledOf(tester, 'テンポ'), isFalse);
    expect(enabledOf(tester, 'ドロップ'), isFalse);
    slider.onChanged!(2);
    await tester.pumpAndSettle();
    expect(find.text('8拍'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8,
        reason: 'PlaylistEngine が読む設定値に保存されること');
  });

  testWidgets('クロスフェード中の設定は、クロスフェードがオンのときだけ触れる', (tester) async {
    await pumpPage(tester, const DjMixSettingsScreen());
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeBeats), 8,
        reason: '前のテストでオンにした値を引き継ぐ（メモリ box は setUpAll で1回だけ開く）');

    // 効果音のタイミングはボタンの下に −/+。押してもメニューは閉じない
    await tester.tap(find.text('タイミング'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('10ms 遅く'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('10ms 遅く'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.sfxOffsetMs), 20);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('+20ms'), findsOneWidget);
    AppBoxes.settings.put(SettingsKeys.sfxOffsetMs, 0);

    // レベルはプリセットなので、選ばれていないものも灰色にしない
    final onSurface = Theme.of(tester.element(find.text('控えめ'))).colorScheme.onSurface;
    for (final l in const ['控えめ', '普通', 'ガチ', 'カスタム']) {
      final color = tester.widget<Text>(find.text(l)).style?.color;
      expect(color == onSurface || color == AppTheme.accentGreen, isTrue,
          reason: l);
    }

    // 既定はおまかせ（普通）。手動の項目もおまかせ中に触れ、変えるとおまかせが切れてカスタムに
    expect(AppBoxes.settings.get(SettingsKeys.autoMix, defaultValue: true), true);
    Color? colorOf(String l) => tester.widget<Text>(find.text(l)).style?.color;
    expect(colorOf('普通'), AppTheme.accentGreen);
    expect(enabledOf(tester, 'テンポ'), isTrue);
    await tester.tap(find.text('テンポ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), false,
        reason: '既定オンなので1回タップでオフになり、PlaylistEngine が読む値に保存される');
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);
    expect(colorOf('カスタム'), AppTheme.accentGreen);

    // 普通に戻してからカスタムを押すと、おまかせだけ切れて個々の設定はそのまま
    await tester.tap(find.text('普通'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), true);
    await tester.tap(find.text('カスタム'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), true);
    expect(colorOf('カスタム'), AppTheme.accentGreen);
    await tester.tap(find.text('テンポ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.tempoMatch), false);

    // 1番はおまかせの横（表示の群ではない）
    final omakase = tester.getRect(find.text('おまかせ'));
    final verse = tester.getRect(find.text('1番'));
    expect((verse.center.dy - omakase.center.dy).abs(), lessThan(16));
    expect(verse.left, greaterThan(omakase.right));

    await tester.tap(find.text('ドロップ'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.mixPointAlign), false);

    // 帯域の入れ替えは既定が低音だけ。メニューで なし / 低音 / 高・中・低
    expect(find.text('低音'), findsOneWidget);
    await tester.tap(find.text('入れ替え'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高・中・低').last);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.bandSwap), 'three');

    // つなぎ方と演出はボタンの下のメニューで選ぶ（ボタンに被せない）
    final button = tester.getRect(find
        .ancestor(of: find.text('つなぎ方'), matching: find.byType(InkWell))
        .first);
    await tester.tap(find.text('つなぎ方'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('次曲先行').last).top,
        greaterThanOrEqualTo(button.bottom));
    await tester.tap(find.text('次曲先行').last);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');
    expect(find.text('次曲先行'), findsOneWidget);

    // 演出の既定はフィルタースイープ（ボタンの下は短い名前、メニューは正式な名前）
    expect(find.text('スイープ'), findsOneWidget);
    await tester.tap(find.text('演出'));
    await tester.pumpAndSettle();
    for (final name in const ['エコーアウト', '残響で消す', 'リバースシンバル', 'クラッシュ', 'フィルターイン']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    await tester.tap(find.text('残響で消す').last);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'reverbTail');
    expect(find.text('残響'), findsOneWidget);
    await tester.tap(find.text('演出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブレーキ').last);
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.transitionEffect), 'brake');

    // クロスフェードをオフにすると触れなくなる（表示の群はそのまま）
    tester.widget<Slider>(find.byType(Slider)).onChanged!(0);
    await tester.pumpAndSettle();
    for (final label in const [
      'おまかせ', 'つなぎ方', 'ドロップ', '出入り口', 'テンポ', '拍合わせ', '入れ替え',
      '演出', '効果音', 'タイミング',
    ]) {
      expect(enabledOf(tester, label), isFalse, reason: label);
    }
    for (final label in const ['拍の線', '一覧の線', '音量の線', '1番']) {
      expect(enabledOf(tester, label), isTrue, reason: label);
    }
  });

  testWidgets('トップのボタンは名前だけ（値の行が無いのでラベルの高さがそろう）。曲数は大きく、バージョンはその下',
      (tester) async {
    AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 16);
    // 前のテストで 3 帯域にした入れ替えを戻す
    AppBoxes.settings.put(SettingsKeys.bandSwap, 'bass');
    await pumpPage(tester, const SettingsScreen());
    for (final t in tester.widgetList<MoreTile>(find.byType(MoreTile))) {
      expect(t.value, isNull, reason: t.label);
      expect(t.active, isNull, reason: t.label);
    }
    final count = find.textContaining('プレイリスト 0');
    final version = find.text('v9.9.9');
    expect(tester.getRect(version).top,
        greaterThan(tester.getRect(count).bottom));
    expect(tester.getSize(count).height,
        greaterThan(tester.getSize(find.text('  ·  更新を確認')).height));
  });

  testWidgets('更新の札を 5 回押すとデバッグモード。トップにデバッグのボタンが出て、終了で消える',
      (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.textContaining('デバッグ'), findsNothing);

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('  ·  更新を確認'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.debugMode), true);
    // 表示・再生の中ではなく、トップの別のボタン
    expect(find.byType(MoreTile), findsNWidgets(5));

    await tester.tap(find.text('デバッグ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テスト版も受け取る'));
    await tester.pumpAndSettle();
    expect(AppBoxes.settings.get(SettingsKeys.betaUpdates), true);

    // 終了するとトップに戻り、ボタンが消え、中の設定も切れる
    await tester.tap(find.text('デバッグモードを終了'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('デバッグ'), findsNothing);
    expect(find.byType(MoreTile), findsNWidgets(4));
    expect(AppBoxes.settings.get(SettingsKeys.debugMode), false);
    expect(AppBoxes.settings.get(SettingsKeys.betaUpdates), false);
  });

  testWidgets('各ページの行には説明文を出さない（値だけ）', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    await tester.tap(find.text('表示・再生'));
    await tester.pumpAndSettle();
    expect(find.text('画面のぼかし'), findsOneWidget);
    expect(find.textContaining('重い端末'), findsNothing);
    expect(find.textContaining('kbps'), findsNothing);
    // 消す操作は保存データへ
    expect(find.text('すべてのデータを削除'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存データ'));
    await tester.pumpAndSettle();
    expect(find.text('すべてのデータを削除'), findsOneWidget);
    expect(find.textContaining('タップで'), findsNothing);
    expect(find.textContaining('残ります'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('バックアップ'));
    await tester.pumpAndSettle();
    expect(find.text('バックアップを書き出す'), findsOneWidget);
    expect(find.textContaining('置き換わ'), findsNothing);
  });

  testWidgets('バージョンが表示される', (tester) async {
    await pumpPage(tester, const SettingsScreen());
    expect(find.text('v9.9.9'), findsOneWidget);
  });
}
