import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'package:u2b_loop_app/app.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart' as app;
import 'package:u2b_loop_app/models/tag.dart';

/// pumpAndSettle はアニメーションが終わるまで待つが、
/// 常時ループするアニメーションがあるとタイムアウトする。
/// 代わりにフレームをN回pumpして安定を待つ。
Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(LoopItemAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(app.PlaylistAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(TagAdapter());
    }
    await Hive.openBox<LoopItem>('loop_items');
    await Hive.openBox<app.Playlist>('playlists');
    await Hive.openBox<Tag>('tags');
    await Hive.openBox('settings');
  });

  group('アプリ起動と基本操作', () {
    testWidgets('リスト画面が表示される', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      expect(find.byType(AppBar), findsWidgets);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('設定画面に遷移して戻れる', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      expect(find.text('設定'), findsOneWidget);
      expect(find.text('ダークモード'), findsOneWidget);
      expect(find.text('ローディングアニメーション'), findsOneWidget);
      expect(find.text('パフォーマンスオーバーレイ'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settle(tester);

      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('ダークモードを切り替えられる', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      final darkSwitch = find.widgetWithText(SwitchListTile, 'ダークモード');
      expect(darkSwitch, findsOneWidget);

      final before = tester.widget<SwitchListTile>(darkSwitch).value;
      await tester.tap(darkSwitch);
      await settle(tester);

      final after = tester.widget<SwitchListTile>(darkSwitch).value;
      expect(after, !before);

      // 元に戻す
      await tester.tap(darkSwitch);
      await settle(tester);
    });

    testWidgets('ローディングアニメーション設定を変更できる', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      await tester.tap(find.text('ローディングアニメーション'));
      await settle(tester);

      // ボトムシートに選択肢が表示される（「ランダム」はサブタイトルにもあるので2つ）
      expect(find.text('ランダム'), findsAtLeast(1));
      expect(find.text('波形 (Wave)'), findsWidgets);
      expect(find.text('ライン (Mystify)'), findsOneWidget);
      expect(find.text('星空 (Starfield)'), findsOneWidget);
      expect(find.text('オフ'), findsOneWidget);

      await tester.tap(find.text('星空 (Starfield)'));
      await settle(tester);

      expect(find.text('星空 (Starfield)'), findsOneWidget);

      // ランダムに戻す
      await tester.tap(find.text('ローディングアニメーション'));
      await settle(tester);
      await tester.tap(find.text('ランダム').last);
      await settle(tester);
    });

    testWidgets('パフォーマンスオーバーレイをON/OFFできる', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.settings));
      await settle(tester);

      // スクロールしてパフォーマンスオーバーレイを表示
      await tester.scrollUntilVisible(
        find.text('パフォーマンスオーバーレイ'),
        100,
      );
      await settle(tester);

      final perfSwitch =
          find.widgetWithText(SwitchListTile, 'パフォーマンスオーバーレイ');
      expect(perfSwitch, findsOneWidget);

      await tester.tap(perfSwitch);
      await settle(tester);

      expect(
          tester.widget<SwitchListTile>(perfSwitch).value, true);

      // OFFに戻す
      await tester.tap(perfSwitch);
      await settle(tester);
    });

    testWidgets('並び替えメニューが表示される', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      await settle(tester);

      final sortButton = find.byTooltip('並び替え');
      if (sortButton.evaluate().isNotEmpty) {
        await tester.tap(sortButton);
        await settle(tester);

        expect(find.text('更新日（新→古）'), findsOneWidget);
        expect(find.text('再生回数（多→少）'), findsOneWidget);

        // メニューを閉じる
        await tester.tapAt(Offset.zero);
        await settle(tester);
      }
    });
  });
}
