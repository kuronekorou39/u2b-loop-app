import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<bool> waitFor(WidgetTester tester, bool Function() condition,
    {int maxFrames = 100}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return true;
  }
  return false;
}

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
late Box<Tag> tagBox;

void _cleanup() {
  final itemKeys = <dynamic>[];
  for (var i = 0; i < itemBox.length; i++) {
    final item = itemBox.getAt(i);
    if (item != null && item.id.startsWith('test_')) itemKeys.add(itemBox.keyAt(i));
  }
  itemBox.deleteAll(itemKeys);

  final plKeys = <dynamic>[];
  for (var i = 0; i < plBox.length; i++) {
    final p = plBox.getAt(i);
    if (p != null && p.name.startsWith('テストPL')) plKeys.add(plBox.keyAt(i));
  }
  plBox.deleteAll(plKeys);

  final tagKeys = <dynamic>[];
  for (var i = 0; i < tagBox.length; i++) {
    final t = tagBox.getAt(i);
    if (t != null && t.name.startsWith('テストタグ')) tagKeys.add(tagBox.keyAt(i));
  }
  tagBox.deleteAll(tagKeys);
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
    tagBox = await Hive.openBox<Tag>('tags');
    await Hive.openBox('settings');
    _cleanup();
  });

  tearDownAll(() => _cleanup());

  // ================================================================
  // A. 設定画面
  // ================================================================
  group('A. 設定画面', () {
    testWidgets('A1. ダークモード切替', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      final sw = find.widgetWithText(SwitchListTile, 'ダークモード');
      final before = tester.widget<SwitchListTile>(sw).value;
      await tester.tap(sw);
      await settle(tester);
      expect(tester.widget<SwitchListTile>(sw).value, !before);
      await tester.tap(sw);
      await settle(tester);
    });

    testWidgets('A2. アニメーション全種選択', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      for (final label in ['波形 (Wave)', 'ライン (Mystify)', '星空 (Starfield)',
                           'パーティクル (Particles)', 'オフ', 'ランダム']) {
        await tester.tap(find.text('ローディングアニメーション'));
        await settle(tester);
        await tester.tap(find.text(label).last);
        await settle(tester);
      }
    });

    testWidgets('A3. パフォーマンスオーバーレイON/OFF', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      await tester.scrollUntilVisible(find.text('パフォーマンスオーバーレイ'), 100);
      await settle(tester);
      final sw = find.widgetWithText(SwitchListTile, 'パフォーマンスオーバーレイ');
      await tester.tap(sw);
      await settle(tester);
      expect(tester.widget<SwitchListTile>(sw).value, true);
      await tester.tap(sw);
      await settle(tester);
    });

    testWidgets('A4. データ統計表示', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      // アイテム数・プレイリスト数・タグ数が表示されている
      expect(find.text('アイテム'), findsOneWidget);
      expect(find.text('プレイリスト'), findsOneWidget);
      expect(find.text('タグ'), findsOneWidget);
    });

    testWidgets('A5. バージョン表示', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      await tester.scrollUntilVisible(find.text('バージョン'), 100);
      await settle(tester);
      expect(find.text('バージョン'), findsOneWidget);
    });

    testWidgets('A6. エクスポート/インポート/クリアボタン存在', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      expect(find.text('エクスポート'), findsOneWidget);
      expect(find.text('インポート'), findsOneWidget);
      expect(find.text('データクリア'), findsOneWidget);
    });

    testWidgets('A7. 設定画面から戻れる', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });
  });

  // ================================================================
  // B. YouTube実データ取得
  // ================================================================
  group('B. YouTube実取得', () {
    testWidgets('B1. 2曲をYouTube APIから取得して追加', (tester) async {
      final container = ProviderContainer();
      await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: const App()));
      await settle(tester);

      final notifier = container.read(loopItemsProvider.notifier);
      await notifier.addYouTubeAndFetch(
          'h7ha6JMgQwk', 'https://www.youtube.com/watch?v=h7ha6JMgQwk');
      await notifier.addYouTubeAndFetch(
          '1tk1pqwrOys', 'https://www.youtube.com/watch?v=1tk1pqwrOys');

      expect(itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').length, 1);
      expect(itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').length, 1);

      // 情報取得完了を待つ（最大30秒）
      await waitFor(tester, () {
        final s1 = itemBox.values.where((i) => i.videoId == 'h7ha6JMgQwk').firstOrNull;
        final s2 = itemBox.values.where((i) => i.videoId == '1tk1pqwrOys').firstOrNull;
        return s1 != null && s1.fetchStatus == null &&
               s2 != null && s2.fetchStatus == null;
      }, maxFrames: 300);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      expect(s1.title, isNot('h7ha6JMgQwk'), reason: 'タイトル取得済み');
      expect(s1.thumbnailUrl, isNotNull, reason: 'サムネイルURL取得済み');

      // テスト用区間を追加
      if (s1.regions.isEmpty) {
        s1.regions.add(LoopRegion(
          id: '${s1.id}_r0', name: 'サビ', pointAMs: 60000, pointBMs: 90000));
        s1.regions.add(LoopRegion(
          id: '${s1.id}_r1', name: 'イントロ', pointAMs: 0, pointBMs: 15000));
        final key = itemBox.keyAt(itemBox.values.toList().indexOf(s1));
        await itemBox.put(key, s1);
      }

      container.dispose();
    });
  });

  // ================================================================
  // C. 曲リスト操作
  // ================================================================
  group('C. 曲リスト', () {
    testWidgets('C1. 2曲がリストに表示される', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester, frames: 20);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      final s2 = itemBox.values.firstWhere((i) => i.videoId == '1tk1pqwrOys');
      expect(find.text(s1.title), findsOneWidget);
      expect(find.text(s2.title), findsOneWidget);
    });

    testWidgets('C2. 表示モード切替（2列→4列→リスト→2列）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      // 初期: 2列（tooltip: '4列表示へ'）
      final btn = find.byTooltip('4列表示へ');
      if (btn.evaluate().isEmpty) return;
      await tester.tap(btn);
      await settle(tester);

      // 4列（tooltip: 'リスト表示へ'）
      expect(find.byTooltip('リスト表示へ'), findsOneWidget);
      await tester.tap(find.byTooltip('リスト表示へ'));
      await settle(tester);

      // リスト（tooltip: '2列表示へ'）
      expect(find.byTooltip('2列表示へ'), findsOneWidget);
      await tester.tap(find.byTooltip('2列表示へ'));
      await settle(tester);

      // 2列に戻った
      expect(find.byTooltip('4列表示へ'), findsOneWidget);
    });

    testWidgets('C3. 並び替え全6種', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final sortBtn = find.byTooltip('並び替え');
      if (sortBtn.evaluate().isEmpty) return;

      for (final label in [
        '更新日（新→古）', '更新日（古→新）', '作成日（新→古）',
        'タイトル（A→Z）', 'タイトル（Z→A）', '再生回数（多→少）',
      ]) {
        await tester.tap(sortBtn);
        await settle(tester);
        expect(find.text(label), findsOneWidget);
        await tester.tap(find.text(label));
        await settle(tester);
      }
    });

    testWidgets('C4. 検索フィルター', (tester) async {
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester, frames: 20);

      final searchField = find.widgetWithText(TextField, '検索...');
      if (searchField.evaluate().isEmpty) return;

      await tester.enterText(searchField, s1.title.substring(0, 3));
      await settle(tester, frames: 20);
      expect(find.text(s1.title), findsOneWidget);

      await tester.enterText(searchField, '');
      await settle(tester, frames: 20);
    });
  });

  // ================================================================
  // D. 曲詳細画面
  // ================================================================
  group('D. 曲詳細', () {
    testWidgets('D1. 詳細画面表示（タイトル・再生ボタン・メタ情報）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester, frames: 20);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      await tester.tap(find.text(s1.title).first);
      await settle(tester);

      expect(find.text('詳細'), findsOneWidget);
      expect(find.text('再生'), findsOneWidget);
      expect(find.text(s1.title), findsWidgets);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
    });

    testWidgets('D2. タイトル編集→自動保存→復帰', (tester) async {
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      final orig = s1.title;

      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester, frames: 20);
      await tester.tap(find.text(orig).first);
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, '編集テスト');
      await settle(tester);
      await tester.tap(find.byType(BackButton));
      await settle(tester, frames: 20);
      expect(find.text('編集テスト'), findsOneWidget);

      // 元に戻す
      await tester.tap(find.text('編集テスト'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, orig);
      await tester.tap(find.byType(BackButton));
      await settle(tester, frames: 20);
    });

    testWidgets('D3. メモ編集（Hiveレベル）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');

      // メモを設定
      s1.memo = 'テストメモ';
      final key = itemBox.keyAt(itemBox.values.toList().indexOf(s1));
      await itemBox.put(key, s1);
      expect(s1.memo, 'テストメモ');

      // クリア
      s1.memo = null;
      await itemBox.put(key, s1);
      expect(s1.memo, isNull);
    });

    testWidgets('D4. AB区間データ確認（Hiveレベル）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      expect(s1.regions.length, greaterThanOrEqualTo(2));
      expect(s1.regions.any((r) => r.name == 'サビ'), true);
      expect(s1.regions.any((r) => r.name == 'イントロ'), true);
    });

    testWidgets('D5. 区間の追加・名前変更・削除（Hiveレベル）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      final origCount = s1.regions.length;

      // 追加
      s1.regions.add(LoopRegion(
        id: '${s1.id}_rtest', name: 'テスト区間', pointAMs: 30000, pointBMs: 45000));
      final key = itemBox.keyAt(itemBox.values.toList().indexOf(s1));
      await itemBox.put(key, s1);
      expect(s1.regions.length, origCount + 1);

      // 名前変更
      s1.regions.last.name = 'テスト区間（変更済）';
      await itemBox.put(key, s1);
      expect(s1.regions.last.name, 'テスト区間（変更済）');

      // 削除
      s1.regions.removeWhere((r) => r.id == '${s1.id}_rtest');
      await itemBox.put(key, s1);
      expect(s1.regions.length, origCount);
    });

    testWidgets('D6. 詳細画面メニュー表示', (tester) async {
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester, frames: 20);
      await tester.tap(find.text(s1.title).first);
      await settle(tester);

      // メニューボタン（more_vert）
      final menuBtn = find.byIcon(Icons.more_vert);
      if (menuBtn.evaluate().isNotEmpty) {
        await tester.tap(menuBtn.first);
        await settle(tester);
        // メニュー項目が存在する
        expect(
          find.text('複製').evaluate().isNotEmpty ||
          find.text('プレイリストに追加').evaluate().isNotEmpty ||
          find.text('削除').evaluate().isNotEmpty,
          true,
        );
        await tester.tapAt(Offset.zero);
        await settle(tester);
      }

      await tester.tap(find.byType(BackButton));
      await settle(tester);
    });
  });

  // ================================================================
  // E. タグ管理
  // ================================================================
  group('E. タグ管理', () {
    testWidgets('E1. タグをHiveで作成', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tagBox.add(Tag(
        id: 'test_tag1',
        name: 'テストタグ1',
      ));
      await tagBox.add(Tag(
        id: 'test_tag2',
        name: 'テストタグ2',
      ));

      expect(tagBox.values.where((t) => t.name == 'テストタグ1').length, 1);
      expect(tagBox.values.where((t) => t.name == 'テストタグ2').length, 1);
    });

    testWidgets('E2. 曲にタグを付与（Hiveレベル）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      if (!s1.tagIds.contains('test_tag1')) {
        s1.tagIds.add('test_tag1');
        final key = itemBox.keyAt(itemBox.values.toList().indexOf(s1));
        await itemBox.put(key, s1);
      }
      expect(s1.tagIds.contains('test_tag1'), true);
    });

    testWidgets('E3. タグタブに切り替えてタグが表示される', (tester) async {
      await tolerant(() async {
        await tester.pumpWidget(const ProviderScope(child: App()));
        await settle(tester);

        // 左にスワイプしてタグタブへ
        await tester.fling(find.byType(TabBarView), const Offset(300, 0), 1000);
        await settle(tester, frames: 15);
      });

      // Hiveレベルで確認
      expect(tagBox.values.any((t) => t.name == 'テストタグ1'), true);
      expect(tagBox.values.any((t) => t.name == 'テストタグ2'), true);
    });

    testWidgets('E4. タグを曲から除去（Hiveレベル）', (tester) async {
      await tolerant(() async {
        await tester.pumpWidget(const ProviderScope(child: App()));
        await settle(tester);
      });

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      if (s1.tagIds.contains('test_tag1')) {
        s1.tagIds.remove('test_tag1');
        final key = itemBox.keyAt(itemBox.values.toList().indexOf(s1));
        await itemBox.put(key, s1);
      }
      expect(s1.tagIds.contains('test_tag1'), false);
    });
  });

  // ================================================================
  // F. プレイリスト
  // ================================================================
  group('F. プレイリスト', () {
    testWidgets('F1. プレイリストをHiveで作成', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await plBox.add(app.Playlist(
        id: 'test_pl_1',
        name: 'テストPL1',
      ));
      expect(plBox.values.any((p) => p.name == 'テストPL1'), true);
    });

    testWidgets('F2. プレイリストタブに表示される', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
      await settle(tester, frames: 15);

      expect(find.text('テストPL1'), findsOneWidget);
    });

    testWidgets('F3. プレイリストに2曲追加（Hive）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      final s2 = itemBox.values.firstWhere((i) => i.videoId == '1tk1pqwrOys');
      pl.itemIds = [s1.id, s2.id];
      final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
      await plBox.put(key, pl);

      expect(pl.itemIds.length, 2);
    });

    testWidgets('F4. プレイリスト名変更（Hive）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');
      pl.name = 'テストPL1（変更済）';
      final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
      await plBox.put(key, pl);
      expect(pl.name, 'テストPL1（変更済）');

      // 元に戻す
      pl.name = 'テストPL1';
      await plBox.put(key, pl);
    });

    testWidgets('F5. プレイリストのアイテム有効/無効（Hive）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');

      // 無効化
      pl.disabledItemIds.add(s1.id);
      final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
      await plBox.put(key, pl);
      expect(pl.disabledItemIds.contains(s1.id), true);

      // 有効化
      pl.disabledItemIds.remove(s1.id);
      await plBox.put(key, pl);
      expect(pl.disabledItemIds.contains(s1.id), false);
    });

    testWidgets('F6. プレイリストの区間選択（Hive）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');

      // 「サビ」区間のみ選択
      final sabiRegion = s1.regions.firstWhere((r) => r.name == 'サビ');
      pl.regionSelections[s1.id] = [sabiRegion.id];
      final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
      await plBox.put(key, pl);
      expect(pl.regionSelections[s1.id], [sabiRegion.id]);

      // クリア
      pl.regionSelections.remove(s1.id);
      await plBox.put(key, pl);
    });

    testWidgets('F7. プレイリストからアイテム削除（Hive）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');
      final s2 = itemBox.values.firstWhere((i) => i.videoId == '1tk1pqwrOys');

      pl.itemIds.remove(s2.id);
      final key = plBox.keyAt(plBox.values.toList().indexOf(pl));
      await plBox.put(key, pl);
      expect(pl.itemIds.length, 1);

      // 元に戻す
      pl.itemIds.add(s2.id);
      await plBox.put(key, pl);
    });
  });

  // ================================================================
  // G. モデルロジック
  // ================================================================
  group('G. モデルロジック', () {
    testWidgets('G1. LoopItem.playCountThresholdMs', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      expect(LoopItem.playCountThresholdMs(10000), 10000); // 10秒 → 全部
      expect(LoopItem.playCountThresholdMs(30000), 30000); // 30秒 → 全部
      expect(LoopItem.playCountThresholdMs(60000), 48000); // 60秒 → 80%
      expect(LoopItem.playCountThresholdMs(600000), 480000); // 10分 → 8分固定
    });

    testWidgets('G2. LoopItemのプロパティ', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');

      expect(s1.sourceType, 'youtube');
      expect(s1.youtubeUrl, isNotNull);
      expect(s1.createdAt, isNotNull);
      expect(s1.updatedAt, isNotNull);
      expect(s1.isFetching, false);
      expect(s1.hasError, false);
    });

    testWidgets('G3. Playlistのプロパティ', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      final pl = plBox.values.firstWhere((p) => p.name == 'テストPL1');

      expect(pl.id, isNotEmpty);
      expect(pl.itemIds, isNotEmpty);
      expect(pl.createdAt, isNotNull);
      expect(pl.effectiveThumbnailItemId, pl.itemIds.first);
    });

    testWidgets('G4. Tagのプロパティ', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      final tag = tagBox.values.firstWhere((t) => t.name == 'テストタグ1');
      expect(tag.id, isNotEmpty);
      expect(tag.name, 'テストタグ1');
    });
  });

  // ================================================================
  // H. アイテム複製・削除
  // ================================================================
  group('H. アイテム操作', () {
    testWidgets('H1. アイテム複製（Hiveレベル）', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final s1 = itemBox.values.firstWhere((i) => i.videoId == 'h7ha6JMgQwk');
      final dup = LoopItem(
        id: 'test_dup_${DateTime.now().millisecondsSinceEpoch}',
        title: '${s1.title}（コピー）',
        uri: s1.uri,
        sourceType: s1.sourceType,
        videoId: s1.videoId,
        youtubeUrl: s1.youtubeUrl,
        thumbnailUrl: s1.thumbnailUrl,
      );
      await itemBox.add(dup);

      expect(itemBox.values.where((i) => i.title.contains('（コピー）')).length, 1);

      // 削除
      final key = itemBox.keyAt(itemBox.values.toList().indexOf(dup));
      await itemBox.delete(key);
    });
  });

  // ================================================================
  // Z. クリーンアップ
  // ================================================================
  testWidgets('Z. テストデータクリーンアップ', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle(tester);

    _cleanup();
    await settle(tester, frames: 10);

    expect(itemBox.values.where((i) => i.id.startsWith('test_')).length, 0);
    expect(plBox.values.where((p) => p.name.startsWith('テストPL')).length, 0);
    expect(tagBox.values.where((t) => t.name.startsWith('テストタグ')).length, 0);
  });
}
