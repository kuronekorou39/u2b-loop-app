import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/pitch_fader.dart';

/// ピッチフェーダー: 上へ動かすと +、全長で ±max、0 の近くは 0 に吸い付く
void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('上へ動かすと + になり、離すと onChangeEnd が来る', (tester) async {
    double value = 0;
    double? ended;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => PitchFader(
        percent: value,
        maxPercent: 8,
        height: 140,
        onChanged: (p) => setState(() => value = p),
        onChangeEnd: (p) => ended = p,
      ),
    )));
    final fader = find.byType(CustomPaint).last;
    final g = await tester.startGesture(tester.getCenter(fader));
    await g.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(value, greaterThan(0));
    // 全長 140 − つまみ 14 = 126px で 16% → 30px ≒ 3.8%
    expect(value, closeTo(30 / 126 * 16, 0.05));
    await g.up();
    await tester.pump();
    expect(ended, closeTo(value, 1e-9));
    expect(find.text(PitchFader.label(value)), findsOneWidget);
  });

  testWidgets('下へ大きく動かしても −max で止まる', (tester) async {
    double value = 0;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => PitchFader(
        percent: value,
        maxPercent: 8,
        onChanged: (p) => setState(() => value = p),
      ),
    )));
    final g = await tester.startGesture(
        tester.getCenter(find.byType(CustomPaint).last));
    await g.moveBy(const Offset(0, 400));
    await tester.pump();
    await g.up();
    expect(value, -8);
  });

  testWidgets('0 の近くは 0 に吸い付く', (tester) async {
    double value = 0;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => PitchFader(
        percent: value,
        maxPercent: 8,
        height: 140,
        onChanged: (p) => setState(() => value = p),
      ),
    )));
    final g = await tester.startGesture(
        tester.getCenter(find.byType(CustomPaint).last));
    // 1px ≒ 0.13% → 吸い付く範囲（0.15%）の中
    await g.moveBy(const Offset(0, -1));
    await tester.pump();
    expect(value, 0);
    await g.up();
  });

  testWidgets('親が描き直さなくても、指で動かしている間はつまみと数字が付いてくる', (tester) async {
    double? last;
    // 親は値を持ったまま更新しない（percent は 0 のまま）
    await tester.pumpWidget(host(PitchFader(
      percent: 0,
      maxPercent: 8,
      height: 140,
      onChanged: (p) => last = p,
    )));
    final g = await tester.startGesture(
        tester.getCenter(find.byType(CustomPaint).last));
    await g.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(last, greaterThan(0));
    expect(find.text(PitchFader.label(last!)), findsOneWidget);
    await g.up();
    await tester.pump();
    // 離したら親の値（0）に戻る
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('onChanged が無ければ見るだけ', (tester) async {
    await tester.pumpWidget(host(const PitchFader(percent: 1.5)));
    expect(find.text('+1.5%'), findsOneWidget);
    final g = await tester.startGesture(
        tester.getCenter(find.byType(CustomPaint).last));
    await g.moveBy(const Offset(0, -30));
    await g.up();
    expect(tester.takeException(), isNull);
  });

  test('表示の文字', () {
    expect(PitchFader.label(0), '0');
    expect(PitchFader.label(0.04), '0');
    expect(PitchFader.label(0.3), '+0.3%');
    expect(PitchFader.label(-1.25), '−1.3%');
  });
}
