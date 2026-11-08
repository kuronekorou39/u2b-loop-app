import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/widgets/player/jog_wheel.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  /// 円盤の中心
  Offset discCenter(WidgetTester tester, {double size = 88}) =>
      tester.getTopLeft(find.byType(JogWheel)) + Offset(size / 2, size / 2);

  testWidgets('回すと値が変わり、離すと onChangeEnd が来る', (tester) async {
    double value = 0;
    bool? lastTouching;
    double? ended;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: value,
        maxMs: 1000,
        onChanged: (ms, {required bool touching}) => setState(() {
          value = ms;
          lastTouching = touching;
        }),
        onChangeEnd: (ms) => ended = ms,
      ),
    )));

    final disc = discCenter(tester);
    // 中心の少し上から右へドラッグ＝時計回り→値が増える
    final gesture = await tester.startGesture(disc + const Offset(0, -24));
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(value, greaterThan(0));
    expect(lastTouching, isTrue);
    await gesture.up();
    // 勢いがあれば少し滑ってから決まる
    await tester.pumpAndSettle();
    expect(ended, closeTo(value, 1e-9));
  });

  testWidgets('maxMs を超えない', (tester) async {
    double value = 0;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: value,
        maxMs: 40,
        onChanged: (ms, {required bool touching}) => setState(() => value = ms),
        onChangeEnd: (_) {},
      ),
    )));
    final g = await tester.startGesture(discCenter(tester) + const Offset(0, -24));
    // 大きく回す（何周も）
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    await g.up();
    expect(value, lessThanOrEqualTo(40));
  });

  testWidgets('動かしていなければ中心に色の点（ずれは出さない）、動かしていれば量が出る', (tester) async {
    await tester.pumpWidget(host(JogWheel(
      periodMs: 500,
      valueMs: 0,
      maxMs: 1000,
      onChanged: (ms, {required bool touching}) {},
      onChangeEnd: (_) {},
    )));
    expect(dot(AppTheme.pointBColor), findsOneWidget);
    expect(find.textContaining('ずれ'), findsNothing);

    await tester.pumpWidget(host(JogWheel(
      periodMs: 500,
      valueMs: -18,
      maxMs: 1000,
      onChanged: (ms, {required bool touching}) {},
      onChangeEnd: (_) {},
    )));
    expect(find.textContaining('−18ms'), findsOneWidget);
    expect(dot(AppTheme.pointBColor), findsNothing);
  });

  testWidgets('表示だけの円盤（前曲）はボタンが無く、触っても下に落ちない', (tester) async {
    var behind = 0;
    await tester.pumpWidget(host(Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => behind++,
          ),
        ),
        Center(
          child: JogWheel.platter(turns: JogWheel.platterTurns(
              const Duration(seconds: 9))),
        ),
      ],
    )));
    expect(dot(AppTheme.pointAColor), findsOneWidget);
    // 円盤の上を押しても、下のタップにならない
    await tester.tap(find.byType(JogWheel), warnIfMissed: false);
    expect(behind, 0);
    // 1.8 秒で 1 周
    expect(JogWheel.platterTurns(const Duration(milliseconds: 1800)), 1);
  });

  /// 時計回りに [steps] 回、[stepMs] ごとに動かす（中心の上 30px の円周をなぞる）
  Future<TestGesture> spin(WidgetTester tester, Offset c,
      {required int steps, required int stepMs, double stepRad = 0.15}) async {
    var t = const Duration(seconds: 1);
    var a = -pi / 2;
    final g = await tester.createGesture();
    await g.down(c + Offset(cos(a), sin(a)) * 30, timeStamp: t);
    for (var i = 0; i < steps; i++) {
      a += stepRad;
      t += Duration(milliseconds: stepMs);
      await g.moveTo(c + Offset(cos(a), sin(a)) * 30, timeStamp: t);
      await tester.pump();
    }
    return g;
  }

  Widget wheel(void Function(double) onValue, {double Function()? value}) =>
      StatefulBuilder(builder: (context, setState) {
        return JogWheel(
          periodMs: 500,
          valueMs: value?.call() ?? 0,
          maxMs: 100000,
          onChanged: (ms, {required bool touching}) =>
              setState(() => onValue(ms)),
          onChangeEnd: (_) {},
        );
      });

  testWidgets('速く回すほど大きく進む（同じ角度でも）', (tester) async {
    Future<double> turn(int stepMs) async {
      var v = 0.0;
      await tester.pumpWidget(host(wheel((ms) => v = ms, value: () => v)));
      final g = await spin(tester, discCenter(tester), steps: 10, stepMs: stepMs);
      // 止めてから離す（滑らせない）
      await tester.pump(const Duration(milliseconds: 200));
      await g.up();
      await tester.pumpAndSettle();
      return v;
    }

    final slow = await turn(100); // 1.5 rad/s
    final fast = await turn(5); // 30 rad/s
    expect(slow, greaterThan(0));
    expect(fast, greaterThan(slow * 2));
  });

  testWidgets('はじくと離した後も滑り、だんだん止まる', (tester) async {
    var v = 0.0;
    double? ended;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: v,
        maxMs: 100000,
        onChanged: (ms, {required bool touching}) => setState(() => v = ms),
        onChangeEnd: (ms) => ended = ms,
      ),
    )));
    final g = await spin(tester, discCenter(tester), steps: 6, stepMs: 16);
    await g.up();
    final atRelease = v;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(v, greaterThan(atRelease), reason: '離した後も進む');
    expect(ended, isNull, reason: '滑っている間はまだ決まらない');
    await tester.pumpAndSettle();
    expect(ended, closeTo(v, 1e-9));
  });

  testWidgets('動かさずに長押しすると微調整（同じだけ回しても少ししか動かない）', (tester) async {
    Future<double> turn({required bool hold}) async {
      var v = 0.0;
      await tester.pumpWidget(host(wheel((ms) => v = ms, value: () => v)));
      final c = discCenter(tester);
      var t = const Duration(seconds: 1);
      var a = -pi / 2;
      final g = await tester.createGesture();
      await g.down(c + Offset(cos(a), sin(a)) * 30, timeStamp: t);
      if (hold) {
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.textContaining('微調整'), findsOneWidget);
      }
      for (var i = 0; i < 10; i++) {
        a += 0.15;
        t += const Duration(milliseconds: 100);
        await g.moveTo(c + Offset(cos(a), sin(a)) * 30, timeStamp: t);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 200));
      await g.up();
      await tester.pumpAndSettle();
      return v;
    }

    final normal = await turn(hold: false);
    final fine = await turn(hold: true);
    expect(fine, greaterThan(0));
    expect(fine, lessThan(normal * 0.5));
    expect(find.textContaining('微調整'), findsNothing, reason: '離せば戻る');
  });
}

/// 円盤の中心の色の点（前曲 = 赤、次曲 = 青）
Finder dot(Color color) => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
    (w.decoration! as BoxDecoration).color == color);
