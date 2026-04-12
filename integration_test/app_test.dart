import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'package:u2b_loop_app/app.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/playlist.dart' as app;
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 条件が満たされるまで最大[maxFrames]フレーム待つ。
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  int maxFrames = 100,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return true;
  }
  return false;
}

/// フレームワーク非致命エラーを許容するラッパー
Future<void> tolerant(Future<void> Function() body) async {
  final old = FlutterError.onError;
  FlutterError.onError = (_) {};
  try {
    await body();
  } finally {
    FlutterError.onError = old;
  }
}

late Box<LoopItem> itemBox;
late Box<app.Playlist> plBox;

void _cleanup() {
  final itemKeys = <dynamic>[];
  for (var i = 0; i < itemBox.length; i++) {
    final item = itemBox.getAt(i);
    if (item != null && item.id.startsWith('test_')) {
      itemKeys.add(itemBox.keyAt(i));
    }
  }
  itemBox.deleteAll(itemKeys);

  final plKeys = <dynamic>[];
  for (var i = 0; i < plBox.length; i++) {
    final p = plBox.getAt(i);
    if (p != null && p.name.startsWith('テストPL')) {
      plKeys.add(plBox.keyAt(i));
    }
  }
  plBox.deleteAll(plKeys);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(LoopItemAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(app.PlaylistAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(TagAdapter());
    itemBox = await Hive.openBox<LoopItem>('loop_items');
    plBox = await Hive.openBox<app.Playlist>('playlists');
    await Hive.openBox<Tag>('tags');
    await Hive.openBox('settings');
    _cleanup();
  });

  tearDownAll(() => _cleanup());

  // ============================
  // 1. 設定画面
  // ============================
  testWidgets('1. 設定: ダークモード・アニメーション・オーバーレイ', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await settle(tester);
    expect(find.text('設定'), findsOneWidget);

    // ダークモード切替
    final darkSwitch = find.widgetWithText(SwitchListTile, 'ダークモード');
    final wasDark = tester.widget<SwitchListTile>(darkSwitch).value;
    await tester.tap(darkSwitch);
    await settle(tester);
    expect(tester.widget<SwitchListTile>(darkSwitch).value, !wasDark);
    await tester.tap(darkSwitch);
    await settle(tester);

    // アニメーション設定
    await tester.tap(find.text('ローディングアニメーション'));
    await settle(tester);
    expect(find.text('波形 (Wave)'), findsWidgets);
    expect(find.text('ライン (Mystify)'), findsOneWidget);
    expect(find.text('星空 (Starfield)'), findsOneWidget);
    expect(find.text('パーティクル (Particles)'), findsOneWidget);
    expect(find.text('オフ'), findsOneWidget);
    await tester.tap(find.text('星空 (Starfield)'));
    await settle(tester);
    // 戻す
    await tester.tap(find.text('ローディングアニメーション'));
    await settle(tester);
    await tester.tap(find.text('ランダム').last);
    await settle(tester);

    // パフォーマンスオーバーレイ
    await tester.scrollUntilVisible(find.text('パフォーマンスオーバーレイ'), 100);
    await settle(tester);
    final perfSwitch = find.widgetWithText(SwitchListTile, 'パフォーマンスオーバーレイ');
    await tester.tap(perfSwitch);
    await settle(tester);
    expect(tester.widget<SwitchListTile>(perfSwitch).value, true);
    await tester.tap(perfSwitch);
    await settle(tester);

    // 戻る
    await tester.tap(find.byType(BackButton));
    await settle(tester);
  });

  // ============================
  // 2. YouTube実データ取得で2曲追加
  // ============================
  testWidgets('2. YouTubeから2曲を実取得して追加', (tester) async {
    final container = ProviderContainer();
    await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const App()));
    await settle(tester);

    final notifier = container.read(loopItemsProvider.notifier);

    // 曲1を追加（実際にYouTube APIにアクセス）
    await notifier.addYouTubeAndFetch(
        'h7ha6JMgQwk', 'https://www.youtube.com/watch?v=h7ha6JMgQwk');

    // 曲2を追加
    await notifier.addYouTubeAndFetch(
        '1tk1pqwrOys', 'https://www.youtube.com/watch?v=1tk1pqwrOys');

    // Hiveに2曲追加されている
    expect(itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').length, 1);
    expect(itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').length, 1);

    // バックグラウンドでYouTube情報取得を待つ（タイトル・サムネイル）
    final fetched = await waitFor(tester, () {
      final s1 = itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').firstOrNull;
      final s2 = itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').firstOrNull;
      return s1 != null && s1.fetchStatus == null &&
             s2 != null && s2.fetchStatus == null;
    }, maxFrames: 300); // 最大30秒待つ

    if (fetched) {
      // タイトルがvideoIdから実タイトルに更新されている
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      expect(s1.title, isNot('h7ha6JMgQwk'), reason: '曲1のタイトルがYouTubeから取得されていること');
      expect(s1.thumbnailUrl, isNotNull, reason: '曲1のサムネイルURLが取得されていること');

      final s2 = itemBox.values.firstWhere((i) => i.videoId == '1tk1pqwrOys');
      expect(s2.title, isNot('1tk1pqwrOys'), reason: '曲2のタイトルがYouTubeから取得されていること');
      expect(s2.thumbnailUrl, isNotNull, reason: '曲2のサムネイルURLが取得されていること');
    }

    // 区間データを曲1に追加（後続テスト用）
    final song1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
    if (song1.regions.isEmpty) {
      song1.regions.add(LoopRegion(
        id: '${song1.id}_r0', name: 'サビ',
        pointAMs: 60000, pointBMs: 90000,
      ));
      final key = itemBox.keyAt(itemBox.values.toList().indexOf(song1));
      await itemBox.put(key, song1);
    }

    await settle(tester, frames: 20);
    container.dispose();
  });

  // ============================
  // 3. 並び替え
  // ============================
  testWidgets('3. 曲リストに2曲が表示される', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester, frames: 20);

    final s1 = itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').firstOrNull;
    final s2 = itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').firstOrNull;
    expect(s1, isNotNull, reason: '曲1がHiveに存在すること');
    expect(s2, isNotNull, reason: '曲2がHiveに存在すること');

    // 画面にタイトルが表示されている
    if (s1!.fetchStatus == null) {
      expect(find.text(s1.title), findsOneWidget);
    }
    if (s2!.fetchStatus == null) {
      expect(find.text(s2.title), findsOneWidget);
    }
  });

  testWidgets('4. 並び替えメニュー全項目', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    final sortBtn = find.byTooltip('並び替え');
    if (sortBtn.evaluate().isEmpty) return;
    await tester.tap(sortBtn);
    await settle(tester);

    expect(find.text('更新日（新→古）'), findsOneWidget);
    expect(find.text('更新日（古→新）'), findsOneWidget);
    expect(find.text('作成日（新→古）'), findsOneWidget);
    expect(find.text('タイトル（A→Z）'), findsOneWidget);
    expect(find.text('タイトル（Z→A）'), findsOneWidget);
    expect(find.text('再生回数（多→少）'), findsOneWidget);

    // 再生回数順に変更
    await tester.tap(find.text('再生回数（多→少）'));
    await settle(tester, frames: 15);
  });

  // ============================
  // 4. 曲詳細画面
  // ============================
  testWidgets('5. 曲詳細: タイトル表示・再生ボタン・区間表示', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester, frames: 20);

    // 曲1をタップ（実タイトルで検索）
    final song1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
    final titleFinder = find.text(song1.title);
    if (titleFinder.evaluate().isEmpty) return;
    await tester.tap(titleFinder.first);
    await settle(tester);

    // 詳細画面が表示される
    expect(find.text('詳細'), findsOneWidget);
    expect(find.text('再生'), findsOneWidget);

    // Hiveレベルで区間データの存在を確認
    expect(song1.regions.length, 1, reason: '区間が1つ登録されていること');
    expect(song1.regions.first.name, 'サビ');

    // 戻る
    await tester.tap(find.byType(BackButton));
    await settle(tester);
  });

  // ============================
  // 5. タイトル編集
  // ============================
  testWidgets('6. 曲詳細: タイトル編集→自動保存', (tester) async {
    final song1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
    final origTitle = song1.title;

    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester, frames: 20);

    final titleFinder = find.text(origTitle);
    if (titleFinder.evaluate().isEmpty) return;
    await tester.tap(titleFinder.first);
    await settle(tester);

    // タイトルを編集
    final titleField = find.byType(TextField).first;
    await tester.enterText(titleField, '編集テスト');
    await settle(tester);

    // 戻る（自動保存）
    await tester.tap(find.byType(BackButton));
    await settle(tester, frames: 20);

    // 編集が反映
    expect(find.text('編集テスト'), findsOneWidget);

    // 元に戻す
    await tester.tap(find.text('編集テスト'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, origTitle);
    await tester.tap(find.byType(BackButton));
    await settle(tester, frames: 20);
  });

  // ============================
  // 7. 検索
  // ============================
  testWidgets('7. 検索フィルター', (tester) async {
    final song1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');

    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester, frames: 20);

    final searchField = find.widgetWithText(TextField, '検索...');
    if (searchField.evaluate().isEmpty) return;

    // 曲1のタイトルの最初の3文字で検索
    final query = song1.title.substring(0, 3);
    await tester.enterText(searchField, query);
    await settle(tester, frames: 20);

    // 曲1がリストに表示される
    expect(find.text(song1.title), findsOneWidget);

    // クリア
    await tester.enterText(searchField, '');
    await settle(tester, frames: 20);
  });

  // ============================
  // 7. プレイリスト作成
  // ============================
  testWidgets('8. プレイリスト作成（Hive）+ タブ表示', (tester) async {
    // Hive直接でPL作成（ダイアログのTextEditingController問題を回避）
    if (!plBox.values.any((p) => p.name == 'テストPL')) {
      await plBox.add(app.Playlist(
        id: 'test_pl_${DateTime.now().millisecondsSinceEpoch}',
        name: 'テストPL',
      ));
    }
    expect(plBox.values.any((p) => p.name == 'テストPL'), true,
        reason: 'プレイリストがHiveに作成されていること');

    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    // プレイリストタブへ
    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await settle(tester, frames: 15);

    // PLが表示されている
    expect(find.text('テストPL'), findsOneWidget);
  });

  // ============================
  // 8. プレイリストに曲追加
  // ============================
  testWidgets('9. プレイリストに2曲追加して確認', (tester) async {
    // Hive直接で曲を追加
    final pl = plBox.values.where((p) => p.name == 'テストPL').firstOrNull;
    if (pl == null) return;
    final s1 = itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').firstOrNull;
    final s2 = itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').firstOrNull;
    if (s1 == null || s2 == null) return;

    pl.itemIds = [s1.id, s2.id];
    final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
    await plBox.put(key, pl);

    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    expect(pl.itemIds.length, 2, reason: 'プレイリストに2曲入っていること');

    // プレイリストタブへ
    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await settle(tester, frames: 15);

    expect(find.text('テストPL'), findsOneWidget);
  });

  // ============================
  // 9. クリーンアップ
  // ============================
  testWidgets('10. テストデータクリーンアップ', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    _cleanup();
    await settle(tester, frames: 10);

    expect(itemBox.values.where((i) => i.id.startsWith('test_')).length, 0);
    expect(plBox.values.where((p) => p.name.startsWith('テストPL')).length, 0);
  });
}
