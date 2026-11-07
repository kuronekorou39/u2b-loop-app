import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/fullscreen_player_view.dart';

/// 全画面の下の板: 右端のピン（コントロールの固定）、左端の反転。ドロワーは外のタップで閉じる
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<List<String>> pump(WidgetTester tester,
      {required bool pinned, bool drawerOpen = false}) async {
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
          drawerOpen: drawerOpen,
          drawer: const SizedBox(),
          onToggleOverlay: noop,
          onToggleDrawer: () => events.add('drawer'),
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

  testWidgets('ピンと反転は下の板の中（左右の端）', (tester) async {
    await pump(tester, pinned: false);
    final pin = tester.getRect(find.byTooltip('コントロールを固定する'));
    final flipH = tester.getRect(find.byTooltip('左右反転'));
    expect(pin.top, greaterThan(300), reason: '上の帯ではなく下の板');
    expect(flipH.left, lessThan(pin.left));
    expect(find.byTooltip('上下反転'), findsOneWidget);
  });

  testWidgets('反転のボタンで動画の向きが切り替わる', (tester) async {
    await pump(tester, pinned: false);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(FullscreenPlayerView)));
    await tester.tap(find.byTooltip('左右反転'));
    await tester.pump();
    expect(container.read(flipHorizontalProvider), isTrue);
    expect(find.byTooltip('左右反転を戻す'), findsOneWidget);
    await tester.tap(find.byTooltip('上下反転'));
    await tester.pump();
    expect(container.read(flipVerticalProvider), isTrue);
  });

  testWidgets('ドロワーを開いている間は、外のタップで閉じる', (tester) async {
    final events = await pump(tester, pinned: false, drawerOpen: true);
    await tester.tapAt(const Offset(200, 200));
    expect(events, ['drawer']);
  });
}
