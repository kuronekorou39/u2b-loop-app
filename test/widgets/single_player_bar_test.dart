import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/models/video_source.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/single_player_bar.dart';

/// 単体再生のコントローラー: AB 編集中は「保存して終了」「元に戻す」「今を A/B」
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<List<String>> pump(WidgetTester tester,
      {required bool editing, bool canRevert = false}) async {
    final events = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        playingProvider.overrideWith((ref) => Stream.value(false)),
        rateProvider.overrideWith((ref) => Stream.value(1.0)),
        videoSourceProvider.overrideWith((ref) =>
            const VideoSource(type: VideoSourceType.local, uri: 'x', title: 'x')),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SinglePlayerBar(
              seekbar: const SizedBox(height: 40),
              loop: const LoopState(),
              onToggleLoop: () {},
              editing: editing,
              canEdit: true,
              onToggleRegions: () => events.add('regions'),
              onEdit: () => events.add('edit'),
              onFinishEdit: () => events.add('finish'),
              onRevert: canRevert ? () => events.add('revert') : null,
              onMore: () => events.add('more'),
              editBlock: const SizedBox(height: 60, key: Key('edit')),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return events;
  }

  testWidgets('編集中は「元に戻す」が押せないときも同じ場所にある', (tester) async {
    await pump(tester, editing: true);
    final disabled = tester.getRect(find.byTooltip('元に戻す（編集を始めたときの A・B）'));
    await pump(tester, editing: true, canRevert: true);
    expect(tester.getRect(find.byTooltip('元に戻す（編集を始めたときの A・B）')), disabled);
  });

  testWidgets('動かしたあとは「元に戻す」で戻せる', (tester) async {
    final events = await pump(tester, editing: true, canRevert: true);
    expect(find.byKey(const Key('edit')), findsOneWidget);
    await tester.tap(find.byTooltip('元に戻す（編集を始めたときの A・B）'));
    await tester.tap(find.text('保存して終了'));
    expect(events, ['revert', 'finish']);
  });

  testWidgets('ふだんは区間・編集のピル（元に戻すは無い）', (tester) async {
    await pump(tester, editing: false);
    expect(find.text('編集'), findsOneWidget);
    expect(find.byTooltip('元に戻す（編集を始めたときの A・B）'), findsNothing);
    expect(find.byKey(const Key('edit')), findsNothing);
  });
}
