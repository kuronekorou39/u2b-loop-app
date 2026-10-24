import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/jog_wheel.dart';
import 'package:u2b_loop_app/widgets/player/mix_deck.dart';
import 'package:u2b_loop_app/widgets/player/pitch_fader.dart';

/// デッキの板: 前曲の盤・次曲のジョグ・ピッチフェーダーが横に並び、幅から円盤の大きさが決まる
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

  testWidgets('合わせられる組: 円盤 2 つ、ジョグにボタン、フェーダー、×2/÷2、BPM', (tester) async {
    var saved = 0, reset = 0, doubled = 0, halved = 0;
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
      onDouble: () => doubled++,
      onHalve: () => halved++,
    )));
    expect(find.byType(JogWheel), findsNWidgets(2));
    expect(find.text('前曲'), findsOneWidget);
    expect(find.textContaining('+12ms'), findsOneWidget);
    expect(find.byType(PitchFader), findsOneWidget);
    expect(find.text('+0.3%'), findsOneWidget);
    expect(find.text('128.0 BPM'), findsOneWidget);
    expect(find.text('127.9 BPM'), findsOneWidget);
    // 幅 372: 円盤は (372 − 24 − 24 − 72) / 2 = 126px
    expect(MixDeck.discSizeFor(372), 126);
    final platter = find.byType(JogWheel).first;
    expect(tester.getSize(platter).width, 126);
    // 左の盤は右の円盤より左
    expect(tester.getCenter(platter).dx,
        lessThan(tester.getCenter(find.byType(JogWheel).last).dx));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    await tester.tap(find.text('×2'));
    await tester.tap(find.text('÷2'));
    expect(saved, 1);
    expect(reset, 1);
    expect(doubled, 1);
    expect(halved, 1);

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

  test('円盤の大きさは幅から。狭い横画面の脇は 90、もっと狭くても 80、タブレットでも 150 まで', () {
    expect(MixDeck.discSizeFor(300), 90);
    expect(MixDeck.discSizeFor(250), 80);
    expect(MixDeck.discSizeFor(800), 150);
  });
}
