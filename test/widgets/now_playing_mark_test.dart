import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/mini_player_provider.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/now_playing_mark.dart';

/// ミニプレイヤーで鳴っている曲・プレイリストにだけ目印を出し、曲が変わればついて動く
void main() {
  LoopItem item(String id) => LoopItem(id: id, title: id, uri: 'u', sourceType: 'local');

  testWidgets('鳴っている曲とプレイリストに目印。曲が進めば移る', (tester) async {
    final container = ProviderContainer(overrides: [
      playingProvider.overrideWith((ref) => Stream.value(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Column(children: [
          SizedBox(width: 40, height: 40, child: Stack(children: [NowPlayingMark(itemId: 'a', key: Key('a'))])),
          SizedBox(width: 40, height: 40, child: Stack(children: [NowPlayingMark(itemId: 'b', key: Key('b'))])),
          SizedBox(width: 40, height: 40, child: Stack(children: [NowPlayingMark(playlistId: 'p', key: Key('p'))])),
        ]),
      ),
    ));
    expect(find.byType(EqualizerBars), findsNothing, reason: '鳴らしていなければ出さない');

    container.read(miniPlayerProvider.notifier)
        .activate(item: item('a'), playlistItems: [item('a'), item('b')], playlistId: 'p');
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('a')), matching: find.byType(EqualizerBars)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('b')), matching: find.byType(EqualizerBars)), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('p')), matching: find.byType(EqualizerBars)), findsOneWidget);

    container.read(miniPlayerProvider.notifier).updateCurrentItem(item('b'));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('a')), matching: find.byType(EqualizerBars)), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('b')), matching: find.byType(EqualizerBars)), findsOneWidget);
    // 棒のアニメーションを止めて終える
    container.read(miniPlayerProvider.notifier).deactivate();
    await tester.pump();
  });
}
