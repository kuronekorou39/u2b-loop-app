import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/widgets/player/deck_anchor.dart';
import 'package:u2b_loop_app/widgets/player/fullscreen_player_view.dart';

/// 全画面の下の板: 右端のピン（コントロールの固定）、左端の反転。ドロワーは外のタップで閉じる
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<List<String>> pump(WidgetTester tester,
      {required bool pinned,
      bool drawerOpen = false,
      Size size = const Size(900, 412)}) async {
    tester.view.physicalSize = size;
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
          seekbar: const SizedBox(
              height: 20, width: double.infinity, key: Key('seek')),
          controls: const SizedBox(height: 40, key: Key('controls')),
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

  testWidgets('DJ の板を出している間は、シークバーだけ右半分へ寄り、左半分が置き場所。再生操作の行は変わらない',
      (tester) async {
    await pump(tester, pinned: false);
    final seek = find.byKey(const Key('seek'));
    final controls = find.byKey(const Key('controls'));
    final full = tester.getRect(seek);
    final controlsBefore = tester.getRect(controls);
    final pinBefore = tester.getRect(find.byTooltip('コントロールを固定する'));
    final anchor = DeckAnchorScope.maybeOf(tester.element(seek))!;
    anchor.setOpen(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final half = tester.getRect(seek);
    expect(half.width, lessThan(full.width * 0.6));
    // 高さの位置は変わらない（右へ寄るだけ）
    expect(half.bottom, closeTo(full.bottom, 0.5));
    expect(half.left, greaterThan(400));
    final target = tester.getRect(find.byType(DeckAnchorTarget));
    expect(target.right, lessThanOrEqualTo(half.left + 0.5));
    expect(target.bottom, lessThanOrEqualTo(controlsBefore.top + 0.5));
    expect(anchor.size.width, greaterThan(300));
    // 再生操作の行（反転・ピンも）は幅も横の位置も同じ
    final controlsAfter = tester.getRect(controls);
    expect(controlsAfter.width, closeTo(controlsBefore.width, 0.5));
    expect(controlsAfter.left, closeTo(controlsBefore.left, 0.5));
    expect(tester.getRect(find.byTooltip('コントロールを固定する')).left,
        closeTo(pinBefore.left, 0.5));
    // 閉じれば元の幅
    anchor.setOpen(false);
    await tester.pumpAndSettle();
    expect(tester.getRect(seek).width, closeTo(full.width, 0.5));
  });

  testWidgets('板を描く大きさは置き場所の今の大きさ（伸びる途中も外へ出ない）',
      (tester) async {
    await pump(tester, pinned: false);
    final seek = find.byKey(const Key('seek'));
    final anchor = DeckAnchorScope.maybeOf(tester.element(seek))!;
    anchor.setOpen(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    final mid = anchor.room.value;
    expect(mid.width, greaterThan(0));
    expect(mid.width, lessThan(anchor.size.width - 1), reason: '伸びる途中');
    expect(mid.height, lessThan(anchor.size.height - 1));
    await tester.pumpAndSettle();
    final target = tester.getSize(find.byType(DeckAnchorTarget));
    expect(anchor.room.value.width, closeTo(target.width, 0.5));
    expect(anchor.room.value.height, closeTo(target.height, 0.5));
    expect(anchor.room.value.width, closeTo(anchor.size.width, 0.5));
  });

  testWidgets('低い画面でも DJ の置き場所は上の帯にかからない', (tester) async {
    await pump(tester, pinned: false, size: const Size(780, 360));
    final seek = find.byKey(const Key('seek'));
    final anchor = DeckAnchorScope.maybeOf(tester.element(seek))!;
    anchor.setOpen(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final target = tester.getRect(find.byType(DeckAnchorTarget));
    expect(target.top, greaterThanOrEqualTo(56));
    expect(anchor.size.height, lessThanOrEqualTo(target.height + 0.5));
  });
}
