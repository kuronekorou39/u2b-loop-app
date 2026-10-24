import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/jog_wheel.dart';
import 'package:u2b_loop_app/widgets/player/mix_deck.dart';
import 'package:u2b_loop_app/widgets/player/pitch_fader.dart';

/// デッキの板: 前曲の盤（小さく薄い）・次曲のジョグ・ピッチフェーダーが横に並び、
/// 幅から円盤の大きさが決まる。組が進んだら中身を左へ送って入れ替える
void main() {
  // 板はガラス板（設定のぼかしを見る）なので、設定の box と ProviderScope が要る
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Widget host(Widget child) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
              body: Align(alignment: Alignment.topLeft, child: child)),
        ),
      );

  testWidgets('合わせられる組: 円盤 2 つ、保存・戻す、フェーダー、BPM', (tester) async {
    var saved = 0, reset = 0;
    double? tempo;
    await tester.pumpWidget(host(MixDeck(
      width: 372,
      outTurns: 0,
      inTurns: 0,
      outBpm: 128,
      inBpm: 127.9,
      jog: (periodMs: 468.75, valueMs: 12, maxMs: 937.5, errorMs: 3),
      tempo: (percent: 0.3, maxPercent: 8),
      onJog: (_, {required bool touching}) {},
      onJogEnd: (_) {},
      onTempo: (p) => tempo = p,
      onTempoEnd: (_) {},
      onSave: () => saved++,
      onReset: () => reset++,
    )));
    expect(find.byType(JogWheel), findsNWidgets(2));
    expect(find.text('前曲'), findsOneWidget);
    expect(find.textContaining('+12ms'), findsOneWidget);
    expect(find.byType(PitchFader), findsOneWidget);
    expect(find.text('+0.3%'), findsOneWidget);
    expect(find.text('128.0 BPM'), findsOneWidget);
    expect(find.text('127.9 BPM'), findsOneWidget);
    // 幅 372: 次曲の円盤は (372 − 24 − 24 − 56) / 1.62 = 165 → 上限 150、前曲は 0.62 倍
    expect(MixDeck.discSizeFor(372), 150);
    expect(MixDeck.subDiscSizeFor(372), closeTo(93, 0.01));
    final platter = find.byType(JogWheel).first;
    final jog = find.byType(JogWheel).last;
    expect(tester.getSize(platter).width, closeTo(93, 0.01));
    expect(tester.getSize(jog).width, 150);
    // 左の盤は右の円盤より左で小さく、下端は揃う
    expect(tester.getCenter(platter).dx, lessThan(tester.getCenter(jog).dx));
    expect(tester.getBottomLeft(platter).dy,
        closeTo(tester.getBottomLeft(jog).dy, 0.01));
    // BPM の 2 行とフェーダーの値は同じ高さ
    final outBpmY = tester.getCenter(find.text('128.0 BPM')).dy;
    expect(tester.getCenter(find.text('127.9 BPM')).dy, closeTo(outBpmY, 0.01));
    expect(tester.getCenter(find.text('+0.3%')).dy, closeTo(outBpmY, 0.01));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    expect(saved, 1);
    expect(reset, 1);
    expect(find.text('×2'), findsNothing);

    // フェーダーを上へ動かすと onTempo が来る
    final fader = find.descendant(
        of: find.byType(PitchFader), matching: find.byType(CustomPaint));
    final g = await tester.startGesture(tester.getCenter(fader.last));
    await g.moveBy(const Offset(0, -20));
    await tester.pump();
    await g.up();
    expect(tempo, greaterThan(0.3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切り替わった後（jog / tempo が null）は両方とも回るだけ', (tester) async {
    await tester.pumpWidget(host(const MixDeck(
      width: 372,
      outTurns: 1.5,
      inTurns: 2,
    )));
    expect(find.text('前曲'), findsOneWidget);
    expect(find.text('次曲'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    expect(find.text('-- BPM'), findsNWidgets(2));
    // フェーダーは 0 のまま見るだけ
    expect(find.text('0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('組が進んだら（contentKey が変わったら）中身を左へ送って入れ替える', (tester) async {
    await tester.pumpWidget(host(const MixDeck(
      key: Key('deck'),
      width: 372,
      contentKey: ValueKey('a>b'),
      outTurns: 0,
      inTurns: 0,
      outBpm: 120,
      inBpm: 128,
    )));
    final rest = tester.getCenter(find.text('120.0 BPM'));
    await tester.pumpWidget(host(const MixDeck(
      key: Key('deck'),
      width: 372,
      contentKey: ValueKey('b>c'),
      outTurns: 0,
      inTurns: 0,
      outBpm: 128,
      inBpm: 100,
    )));
    await tester.pump(const Duration(milliseconds: 120));
    // 出る側（120）は左へ、入る側（100）は右から
    expect(tester.getCenter(find.text('120.0 BPM')).dx, lessThan(rest.dx));
    expect(tester.getCenter(find.text('100.0 BPM')).dx,
        greaterThan(tester.getCenter(find.text('120.0 BPM')).dx));
    await tester.pumpAndSettle();
    expect(find.text('120.0 BPM'), findsNothing);
    expect(tester.getCenter(find.text('128.0 BPM')), rest);
    expect(tester.takeException(), isNull);
  });

  test('円盤の大きさは幅から。狭い横画面の脇は 121、もっと狭くても 80、タブレットでも 150 まで', () {
    expect(MixDeck.discSizeFor(300), closeTo(121, 0.02));
    expect(MixDeck.discSizeFor(250), closeTo(90.1, 0.05));
    expect(MixDeck.discSizeFor(200), 80);
    expect(MixDeck.discSizeFor(800), 150);
    expect(MixDeck.subDiscSizeFor(800), closeTo(93, 0.01));
  });
}
