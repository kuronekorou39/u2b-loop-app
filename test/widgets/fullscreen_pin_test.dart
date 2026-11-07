import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/player/fullscreen_player_view.dart';

/// 全画面の上の帯のピン: 押すと呼び出し側へ届き、留めている間は塗りのピンになる
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<List<String>> pump(WidgetTester tester, {required bool pinned}) async {
    tester.view.physicalSize = const Size(900, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = <String>[];
    void noop() {}
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: FullscreenPlayerView(
          title: '曲',
          subtitle: '',
          bottomInset: 0,
          showOverlay: true,
          overlayPinned: pinned,
          onToggleOverlayPin: () => events.add('pin'),
          drawerOpen: false,
          drawer: const SizedBox(),
          onToggleOverlay: noop,
          onToggleDrawer: noop,
          onExit: noop,
          onSubtitleLongPress: noop,
          onRetryWaveform: noop,
          isPlaylist: false,
          video: const ColoredBox(color: Colors.black),
          seekbar: const SizedBox(height: 20),
          controls: const SizedBox(height: 40),
        ),
      ),
    ));
    await tester.pump();
    return events;
  }

  testWidgets('留めていないときは枠のピン。押すと届く', (tester) async {
    final events = await pump(tester, pinned: false);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    await tester.tap(find.byTooltip('コントロールを固定する'));
    expect(events, ['pin']);
  });

  testWidgets('留めているときは塗りのピン', (tester) async {
    await pump(tester, pinned: true);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byTooltip('コントロールの固定を外す'), findsOneWidget);
  });
}
