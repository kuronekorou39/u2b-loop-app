import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist_track.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/widgets/player/track_row_parts.dart';

/// 再生中のトラック一覧のタグ: プレイリストが自動で入れるタグが 1 つだけなら、
/// そのタグ（どの曲にも付いている）は出さない
void main() {
  final tags = {
    'r': Tag(id: 'r', name: 'ロック', order: 0),
    'j': Tag(id: 'j', name: 'ジャズ', order: 1),
  };
  final track = PlaylistTrack(
    item: LoopItem(
        id: 'a',
        title: '曲A',
        uri: '/a.mp4',
        sourceType: 'local',
        tagIds: ['r', 'j']),
    itemIndex: 0,
  );

  Future<void> pump(WidgetTester tester, {String? hidden}) =>
      tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Row(
            children: trackTagChips(context, track, tags, hiddenTagId: hidden),
          ),
        ),
      ));

  testWidgets('隠すタグが無ければ全部出す', (tester) async {
    await pump(tester);
    expect(find.text('ロック'), findsOneWidget);
    expect(find.text('ジャズ'), findsOneWidget);
  });

  testWidgets('隠すタグは出さず、ほかのタグは出す', (tester) async {
    await pump(tester, hidden: 'r');
    expect(find.text('ロック'), findsNothing);
    expect(find.text('ジャズ'), findsOneWidget);
  });
}
