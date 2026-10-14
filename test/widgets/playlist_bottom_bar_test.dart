import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/playlist_mode.dart' as pl;
import 'package:u2b_loop_app/models/video_source.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/playlist_bottom_bar.dart';

/// プレイリストのコントローラー: ふだんのピルと AB 編集中のピルの切り替え、
/// 一覧を開いている間は編集ブロックとピル行をしまう
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<({List<String> events})> pump(
    WidgetTester tester, {
    bool editing = false,
    bool compact = false,
    bool canRegister = true,
  }) async {
    final events = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        playingProvider.overrideWith((ref) => Stream.value(false)),
        videoSourceProvider.overrideWith((ref) =>
            const VideoSource(type: VideoSourceType.local, uri: 'x', title: 'x')),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PlaylistBottomBar(
              seekbar: const SizedBox(height: 40, key: Key('seek')),
              compact: compact,
              shuffle: false,
              onShuffle: () => events.add('shuffle'),
              repeatMode: pl.RepeatMode.none,
              onRepeat: () => events.add('repeat'),
              onPrev: () => events.add('prev'),
              onNext: () => events.add('next'),
              onMore: () => events.add('more'),
              onToggleList: () => events.add('list'),
              firstVerse: false,
              onToggleFirstVerse: () => events.add('firstVerse'),
              editing: editing,
              editBlock: const SizedBox(height: 60, key: Key('edit')),
              onFinishEdit: () => events.add('finish'),
              onSetA: () => events.add('setA'),
              onSetB: () => events.add('setB'),
              onRegister: canRegister ? () => events.add('register') : null,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return (events: events);
  }

  testWidgets('ふだんはトラック一覧・1番・その他のピル', (tester) async {
    final r = await pump(tester);
    expect(find.text('トラック一覧'), findsOneWidget);
    expect(find.text('1番'), findsOneWidget);
    expect(find.byKey(const Key('edit')), findsNothing);
    await tester.tap(find.text('トラック一覧'));
    await tester.tap(find.byTooltip('その他'));
    expect(r.events, ['list', 'more']);
  });

  testWidgets('編集中は編集ブロックと 終了・今を A/B・登録 のピル', (tester) async {
    final r = await pump(tester, editing: true);
    expect(find.byKey(const Key('edit')), findsOneWidget);
    expect(find.text('トラック一覧'), findsNothing);
    await tester.tap(find.text('今をA'));
    await tester.tap(find.text('今をB'));
    await tester.tap(find.byTooltip('この A–B を区間として登録'));
    await tester.tap(find.text('終了'));
    expect(r.events, ['setA', 'setB', 'register', 'finish']);
  });

  testWidgets('A・B が揃っていなければ登録は無効', (tester) async {
    final r = await pump(tester, editing: true, canRegister: false);
    await tester.tap(find.byTooltip('A と B を決めると区間として登録できます'));
    expect(r.events, isEmpty);
  });

  testWidgets('一覧を開いている間は編集ブロックとピル行をしまう', (tester) async {
    await pump(tester, editing: true, compact: true);
    expect(find.byKey(const Key('edit')), findsNothing);
    expect(find.text('終了'), findsNothing);
    expect(find.byKey(const Key('seek')), findsOneWidget);
  });
}
