import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/perf_overlay.dart';

/// 計測の表示: 渡した高さ（ミニプレイヤーが出ていればその上）に出て、触っても下に届く
void main() {
  testWidgets('下端から bottom の高さに出る。触れても下のボタンが押せる', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 90,
            height: 40,
            child: TextButton(onPressed: () => taps++, child: const Text('下')),
          ),
          const PerfOverlay(bottom: 100),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    final pill = tester.getRect(find.textContaining('FPS'));
    expect(pill.bottom, lessThanOrEqualTo(800 - 100));
    expect(pill.bottom, greaterThan(800 - 100 - 24));
    await tester.tapAt(Offset(200, pill.center.dy));
    expect(taps, 1);
  });
}
