import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_view.dart';

/// 帯の上に重ねたもの（円盤）はそこだけタッチを取り、空いているところは帯のシークに落ちる
void main() {
  testWidgets('重ねたものの上はそちら、空いた所は帯のシーク', (tester) async {
    var seeks = 0, onWheel = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: MixView(
            outWaveform: const [0.5, 0.5],
            outDuration: const Duration(seconds: 200),
            outTitle: 'A',
            inWaveform: const [0.5, 0.5],
            inDuration: const Duration(seconds: 200),
            inStart: const Duration(seconds: 10),
            inTitle: 'B',
            start: const Duration(seconds: 100),
            cut: const Duration(seconds: 110),
            now: const Duration(seconds: 95),
            swapped: false,
            window: const MixWindow(Duration(seconds: 90), Duration(seconds: 120)),
            height: 96,
            onSeek: (_) => seeks++,
            overlay: Center(
              child: GestureDetector(
                key: const Key('wheel'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onWheel++,
                child: const SizedBox(width: 60, height: 60),
              ),
            ),
          ),
        ),
      ),
    ));
    // 帯の幅・位置は overlay の有無で変わらない（帯は 400px いっぱい）
    expect(tester.getSize(find.byType(MixView)).width, 400);
    await tester.tap(find.byKey(const Key('wheel')));
    expect(onWheel, 1);
    expect(seeks, 0);
    // 左端（円盤の外）は帯のシーク
    await tester.tapAt(tester.getTopLeft(find.byType(MixView)) + const Offset(10, 48));
    expect(seeks, 1);
    expect(onWheel, 1);
  });
}
