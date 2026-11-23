import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/audio_quality.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/now_playing_header.dart';

/// 再生画面の曲名行: 曲名は 1 行目を幅いっぱいに使い、チップ（次の曲・いまの区間）は
/// その下の段の右端、左は補足と音質の 2 行。以前はチップが曲名の行の右にあり、曲名が短く切れていた
void main() {
  Future<void> pump(WidgetTester tester,
      {Widget? chip, AudioQuality? quality}) async {
    tester.view.physicalSize = const Size(411, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [activeAudioQualityProvider.overrideWith((ref) => quality)],
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

  testWidgets('チップは補足の段の右端（曲名の行には並べない）', (tester) async {
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
    expect(chip.top, lessThan(sub.bottom), reason: '補足と同じ段');
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

  testWidgets('補足と音質は 2 行に分け、音質が決まる前後で高さが変わらない', (tester) async {
    await pump(tester);
    final before = tester.getSize(find.byType(NowPlayingHeader)).height;
    // override の差し替えは効かないので、ProviderScope を作り直す
    await tester.pumpWidget(const SizedBox());
    await pump(tester, quality: AudioQuality.offline);
    final sub = tester.getRect(find.text('120 BPM'));
    final q = tester.getRect(find.text(AudioQuality.offline.label));
    expect(q.top, greaterThanOrEqualTo(sub.bottom - 0.5));
    expect(q.left, closeTo(sub.left, 0.5));
    expect(tester.getSize(find.byType(NowPlayingHeader)).height, before);
  });

  testWidgets('チップが無ければ補足の行だけ', (tester) async {
    await pump(tester);
    expect(find.byType(HeaderChip), findsNothing);
    expect(find.text('120 BPM'), findsOneWidget);
  });
}
