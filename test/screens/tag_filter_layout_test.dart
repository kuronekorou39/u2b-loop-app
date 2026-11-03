import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/screens/home/tag_filter_bar.dart';
import 'package:u2b_loop_app/widgets/selection_mark.dart';

/// タグで絞り込んでも、一覧とシートの中身の位置が動かない
void main() {
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(TagAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  final tags = [
    for (var i = 0; i < 5; i++) Tag(id: 't$i', name: 'タグ$i', order: i),
  ];

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            SelectedTagBar(tags: tags),
            const Expanded(child: Text('一覧', key: Key('list'))),
          ]),
        ),
      ),
    ));
    return container;
  }

  testWidgets('タグを選んでも一覧の位置は変わらない', (tester) async {
    final c = await pump(tester);
    final before = tester.getRect(find.byKey(const Key('list')));
    c.read(tagFilterProvider.notifier).state = {'t0': true, 't1': false};
    await tester.pumpAndSettle();
    expect(find.text('タグ0'), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('list'))), before);
  });

  testWidgets('シートの中で選んでも、タグの行の位置は変わらない', (tester) async {
    await pump(tester);
    await tester.tap(find.text('タグで絞り込み'));
    await tester.pumpAndSettle();
    final before = tester.getRect(find.text('タグ3').last);
    await tester.tap(find.text('タグ1').last);
    await tester.pumpAndSettle();
    expect(find.text('クリア'), findsWidgets);
    expect(tester.getRect(find.text('タグ3').last), before);
  });

  testWidgets('複数選択中は選んでいないものだけ暗くなる', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [
        SelectionDim(selecting: true, selected: true, child: Text('a')),
        SelectionDim(selecting: true, selected: false, child: Text('b')),
        SelectionDim(selecting: false, selected: false, child: Text('c')),
      ]),
    ));
    double opacity(String t) => tester
        .widget<AnimatedOpacity>(
            find.ancestor(of: find.text(t), matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity('a'), 1);
    expect(opacity('b'), SelectionDim.dimOpacity);
    expect(opacity('c'), 1);
  });

  test('タグのサムネ: 選んだ曲、無ければよく再生した曲', () {
    final tag = Tag(id: 't', name: 'x');
    LoopItem item(String id, {int plays = 0, bool thumb = true, bool tagged = true}) =>
        LoopItem(
          id: id,
          title: id,
          uri: 'u',
          sourceType: 'local',
          playCount: plays,
          tagIds: tagged ? ['t'] : [],
          thumbnailPath: thumb ? '/p/$id.jpg' : null,
        );
    final items = [
      item('a', plays: 1),
      item('b', plays: 5),
      item('c', plays: 9, thumb: false),
      item('d', plays: 20, tagged: false),
    ];
    expect(tag.thumbItemOf(items)?.id, 'b');
    tag.thumbItemId = 'a';
    expect(tag.thumbItemOf(items)?.id, 'a');
    tag.thumbItemId = 'd';
    expect(tag.thumbItemOf(items)?.id, 'b', reason: 'タグが外れた曲は使わない');
  });
}
