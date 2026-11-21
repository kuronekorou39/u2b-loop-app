import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/now_playing_header.dart';

/// 再生画面の曲名行: 曲名は 1 行目を幅いっぱいに使い、チップ（次の曲・いまの区間）は
/// 2 行目（補足の行）の右端。以前はチップが曲名の行の右にあり、曲名が短く切れていた
void main() {
  Future<void> pump(WidgetTester tester, {Widget? chip}) async {
    tester.view.physicalSize = const Size(411, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [activeAudioQualityProvider.overrideWith((ref) => null)],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: NowPlayingHeader(
              title: '曲の名前',
              subtitle: '120 BPM',
              chip: chip,
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('チップは補足の行の右端（曲名の行には並べない）', (tester) async {
    await pump(tester,
        chip: HeaderChip(
          leading: const Icon(Icons.repeat, size: 16),
          label: '区間',
          text: 'サビ',
          onTap: () {},
        ));
    final title = tester.getRect(find.text('曲の名前'));
    final sub = tester.getRect(find.text('120 BPM'));
    final chip = tester.getRect(find.byType(HeaderChip));
    expect(chip.top, greaterThanOrEqualTo(title.bottom - 0.5), reason: '曲名の下');
    expect((chip.center.dy - sub.center.dy).abs(), lessThan(2), reason: '補足と同じ行');
    // 曲名行の左右の余白は AppSpacing.xl + 4
    expect(chip.right, closeTo(411 - (AppSpacing.xl + 4), 0.5), reason: '右端');
    expect(chip.left, greaterThan(sub.right));
    // チップの中は 1 行（ラベルと本文が横並び）
    expect(tester.getCenter(find.text('区間')).dy,
        closeTo(tester.getCenter(find.text('サビ')).dy, 1));
  });

  testWidgets('長い区間名はチップの幅の上限で切る', (tester) async {
    await pump(tester,
        chip: HeaderChip(
          leading: const Icon(Icons.repeat, size: 16),
          label: '区間',
          text: 'とても長い区間の名前' * 5,
          onTap: () {},
        ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(HeaderChip)).width,
        lessThanOrEqualTo(HeaderChip.maxWidth + 16 + 0.5));
  });

  testWidgets('チップが無ければ補足の行だけ', (tester) async {
    await pump(tester);
    expect(find.byType(HeaderChip), findsNothing);
    expect(find.text('120 BPM'), findsOneWidget);
  });
}
