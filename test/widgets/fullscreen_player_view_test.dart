import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/providers/playlist_player_provider.dart';
import 'package:u2b_loop_app/widgets/player/fullscreen_player_view.dart';

/// 全画面ドロワーの中身。プレイリスト: 上の 1 行（前後・シャッフル・リピート・その他）、
/// 単体: ループ・編集・書き出し + 区間の一覧。再生画面から切り出したので、
/// 操作がそのまま呼び出し側に届くことと、無効の条件を確かめる
void main() {
  LoopItem item(String id) => LoopItem(
        id: id,
        title: '曲 $id',
        uri: 'u',
        sourceType: SourceTypes.local,
      );

  group('FullscreenPlaylistControls', () {
    Future<List<String>> pump(WidgetTester tester,
        {int tracks = 3, bool canShuffle = true}) async {
      final events = <String>[];
      final notifier = PlaylistPlayerNotifier()
        ..loadPlaylist([for (var i = 0; i < tracks; i++) item('$i')]);
      await tester.pumpWidget(ProviderScope(
        overrides: [playlistPlayerProvider.overrideWith((_) => notifier)],
        child: MaterialApp(
          home: Scaffold(
            body: FullscreenPlaylistControls(
              onShuffle: canShuffle ? () => events.add('shuffle') : null,
              onRepeat: () => events.add('repeat'),
              onPrev: () => events.add('prev'),
              onNext: () => events.add('next'),
              onMore: () => events.add('more'),
            ),
          ),
        ),
      ));
      return events;
    }

    testWidgets('n / 全 を出し、次・その他・リピートが届く', (tester) async {
      final events = await pump(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.byTooltip('次の曲'));
      await tester.tap(find.byTooltip('その他'));
      await tester.tap(find.byTooltip('リピートなし'));
      await tester.tap(find.byTooltip('シャッフル'));
      expect(events, ['next', 'more', 'repeat', 'shuffle']);
    });

    testWidgets('先頭では「前の曲」が無効', (tester) async {
      final events = await pump(tester);
      await tester.tap(find.byTooltip('前の曲'));
      expect(events, isNot(contains('prev')));
    });

    testWidgets('onShuffle が null ならシャッフルは無効（プリロード中）', (tester) async {
      final events = await pump(tester, canShuffle: false);
      await tester.tap(find.byTooltip('シャッフル'));
      expect(events, isEmpty);
    });
  });

  group('FullscreenRegionDrawer', () {
    final regions = [
      LoopRegion(id: 'r1', name: 'サビ', pointAMs: 1000, pointBMs: 5000),
      LoopRegion(id: 'r2', name: '間奏', pointAMs: 8000, pointBMs: 9000),
    ];

    Future<List<String>> pump(WidgetTester tester,
        {int active = 0, bool canAdd = true, bool hasSource = true}) async {
      final events = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FullscreenRegionDrawer(
            regions: regions,
            activeIndex: active,
            loop: const LoopState(enabled: true),
            bottomInset: 0,
            onToggleLoop: hasSource ? () => events.add('loop') : null,
            onEdit: () => events.add('edit'),
            onExport: ({required fullTrack}) =>
                events.add('export:${fullTrack ? 'full' : 'ab'}'),
            onSelectAll: () => events.add('all'),
            onSelect: (i) => events.add('select:$i'),
            onMenu: (i) => events.add('menu:$i'),
            onAdd: canAdd ? () => events.add('add') : null,
          ),
        ),
      ));
      return events;
    }

    testWidgets('全体 + 各区間の行。タップで選択、⋮ でメニュー', (tester) async {
      final events = await pump(tester);
      expect(find.text('全体'), findsOneWidget);
      expect(find.text('サビ'), findsOneWidget);
      await tester.tap(find.text('間奏'));
      await tester.tap(find.text('全体'));
      expect(events, ['select:1', 'all']);
    });

    testWidgets('編集は区間を選んでいるときだけ。追加は上限で消える', (tester) async {
      await pump(tester, active: -1, canAdd: false);
      expect(find.text('編集'), findsNothing);
      expect(find.text('区間追加'), findsNothing);
      final events = await pump(tester, active: 0);
      await tester.tap(find.text('編集'));
      await tester.tap(find.text('区間追加'));
      expect(events, ['edit', 'add']);
    });

    testWidgets('書き出しは A・B が無ければ全体として呼ぶ', (tester) async {
      final events = await pump(tester);
      await tester.tap(find.byTooltip('書き出し'));
      // LoopState(enabled: true) は A・B 未設定
      expect(events, ['export:full']);
    });

    testWidgets('ソースが無い間はループの切り替えが無効', (tester) async {
      final events = await pump(tester, hasSource: false);
      await tester.tap(find.byTooltip('ループ ON'));
      expect(events, isEmpty);
    });
  });
}
