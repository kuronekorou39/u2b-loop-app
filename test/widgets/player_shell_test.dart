import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/providers/subtitle_provider.dart';
import 'package:u2b_loop_app/widgets/player/deck_anchor.dart';
import 'package:u2b_loop_app/widgets/player/player_shell.dart';

/// 再生画面の骨組み: 動画は 16:9 で、画面が短いときだけコントローラーを優先して縮む。
/// パネルの開閉で中段が切り替わる
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  final item = LoopItem(id: 'x', title: 't', uri: 'u', sourceType: 'local');

  Future<void> pump(
    WidgetTester tester, {
    required double height,
    required double controllerHeight,
    Widget? panel,
    double width = 400,
    bool wide = false,
    Widget? topBar,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        // 字幕オフ（KaraokeSubtitle がプレイヤーに触らないように）
        subtitleModeProvider.overrideWith((ref) => SubtitleMode.off),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
      ],
      child: MaterialApp(
        home: Scaffold(
          extendBodyBehindAppBar: true,
          // 横レイアウトは AppBar なし（topBar がその代わり）
          appBar: wide ? null : AppBar(backgroundColor: Colors.transparent),
          body: PlayerShell(
            item: item,
            wide: wide,
            topBar: topBar,
            video: const ColoredBox(color: Colors.black, key: Key('video')),
            header: const SizedBox(height: 40, key: Key('header')),
            panel: panel,
            controller: SizedBox(height: controllerHeight, key: const Key('ctrl')),
          ),
        ),
      ),
    ));
    // 測ってから反映するので 2 フレーム + アニメーション
    await tester.pumpAndSettle();
  }

  group('横レイアウト（wide）', () {
    testWidgets('左に topBar・動画（上寄せ）・曲名行、右にコントローラー（下端）', (tester) async {
      await pump(tester,
          width: 900,
          height: 400,
          controllerHeight: 250,
          wide: true,
          topBar: const SizedBox(height: 40, key: Key('topBar')));
      expect(tester.takeException(), isNull);
      final topBar = tester.getRect(find.byKey(const Key('topBar')));
      final video = tester.getRect(find.byKey(const Key('video')));
      final header = tester.getRect(find.byKey(const Key('header')));
      final ctrl = tester.getRect(find.byKey(const Key('ctrl')));
      final split = 900 * PlayerShell.wideLeftRatio;
      // 左の列: topBar → 動画（16:9、列の幅いっぱい）→ 曲名行
      expect(topBar.left, closeTo(0, 0.5));
      expect(topBar.right, closeTo(split, 0.5));
      expect(video.top, greaterThanOrEqualTo(topBar.bottom - 0.5));
      expect(video.width / video.height, closeTo(16 / 9, 0.01));
      expect(video.width, closeTo(split - PlayerShell.margin * 2, 0.5));
      expect(header.top, greaterThanOrEqualTo(video.bottom - 0.5));
      // 右の列: コントローラー（下端）
      expect(ctrl.left, closeTo(split, 0.5));
      expect(ctrl.bottom, closeTo(400, 0.5));
    });

    testWidgets('パネルは左の列に重なり、右の列にはかからない', (tester) async {
      await pump(tester,
          width: 900,
          height: 400,
          controllerHeight: 250,
          wide: true,
          panel: const ColoredBox(color: Colors.red, key: Key('panel')));
      final panel = tester.getRect(find.byKey(const Key('panel')));
      final video = tester.getRect(find.byKey(const Key('video')));
      expect(panel.left, closeTo(0, 0.5));
      expect(panel.right, closeTo(900 * PlayerShell.wideLeftRatio, 0.5));
      expect(panel.top, lessThanOrEqualTo(video.top + 0.5));
      expect(panel.bottom, closeTo(400, 0.5));
    });

    testWidgets('デッキの置き場所は左の列。板を出している間は曲名行を隠す', (tester) async {
      await pump(tester,
          width: 900, height: 400, controllerHeight: 250, wide: true);
      final anchor = DeckAnchorScope.maybeOf(
          tester.element(find.byKey(const Key('header'))))!;
      expect(anchor.size.width,
          closeTo(900 * PlayerShell.wideLeftRatio - PlayerShell.margin * 2, 0.5));
      expect(anchor.size.height, greaterThan(300));
      anchor.setOpen(true);
      await tester.pumpAndSettle();
      final header = tester.widget<Visibility>(find.ancestor(
          of: find.byKey(const Key('header')),
          matching: find.byType(Visibility)));
      expect(header.visible, isFalse);
    });

    testWidgets('低い画面でも溢れない', (tester) async {
      await pump(tester,
          width: 800, height: 360, controllerHeight: 250, wide: true);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const Key('ctrl'))).bottom,
          closeTo(360, 0.5));
    });
  });

  testWidgets('十分な高さなら動画は 16:9 のまま', (tester) async {
    await pump(tester, height: 900, controllerHeight: 300);
    final size = tester.getSize(find.byKey(const Key('video')));
    expect(size.width, closeTo(400 - PlayerShell.margin * 2, 0.5));
    expect(size.height, closeTo(size.width * 9 / 16, 0.5));
  });

  testWidgets('短い画面ではコントローラーを優先して動画が縮む', (tester) async {
    await pump(tester, height: 700, controllerHeight: 400);
    final size = tester.getSize(find.byKey(const Key('video')));
    final full = (400 - PlayerShell.margin * 2) * 9 / 16;
    expect(size.height, lessThan(full));
    expect(size.height, greaterThanOrEqualTo(full * PlayerShell.videoMinScale - 0.5));
    // 比率は保つ（レターボックス）
    expect(size.width / size.height, closeTo(16 / 9, 0.01));
    // コントローラーは画面内に収まっている
    final ctrl = tester.getRect(find.byKey(const Key('ctrl')));
    expect(ctrl.bottom, lessThanOrEqualTo(700 + 0.5));
  });

  testWidgets('パネルは動画と曲名行の上に重なり、コントローラーの上で止まる。null で消える',
      (tester) async {
    await pump(tester,
        height: 900,
        controllerHeight: 200,
        panel: const ColoredBox(color: Colors.red, key: Key('panel')));
    expect(find.byKey(const Key('panel')), findsOneWidget);
    final panel = tester.getRect(find.byKey(const Key('panel')));
    final video = tester.getRect(find.byKey(const Key('video')));
    final header = tester.getRect(find.byKey(const Key('header')));
    final ctrl = tester.getRect(find.byKey(const Key('ctrl')));
    // 動画の上端から曲名行の下端までを覆う
    expect(panel.top, lessThanOrEqualTo(video.top + 0.5));
    expect(panel.bottom, greaterThan(header.bottom));
    expect(panel.bottom, lessThanOrEqualTo(ctrl.top + 0.5));
    // 開いても動画は縮まない
    expect(video.height, closeTo((400 - PlayerShell.margin * 2) * 9 / 16, 0.5));

    await pump(tester, height: 900, controllerHeight: 200, panel: null);
    expect(find.byKey(const Key('panel')), findsNothing);
  });

  testWidgets('コントローラーが伸び縮みする途中もパネルの下端が追従する', (tester) async {
    // 波形の開閉のように、コントローラーの高さは AnimatedSize で変わる
    final height = ValueNotifier<double>(200);
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        subtitleModeProvider.overrideWith((ref) => SubtitleMode.off),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
      ],
      child: MaterialApp(
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: PlayerShell(
            item: item,
            video: const ColoredBox(color: Colors.black, key: Key('video')),
            header: const SizedBox(height: 40, key: Key('header')),
            panel: const ColoredBox(color: Colors.red, key: Key('panel')),
            controller: ValueListenableBuilder<double>(
              valueListenable: height,
              // 伸び縮みしているのは AnimatedSize 自身（中の SizedBox は即座に新しい高さ）
              builder: (_, h, _) => AnimatedSize(
                key: const Key('ctrl'),
                duration: const Duration(milliseconds: 300),
                child: SizedBox(height: h),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    height.value = 320;
    await tester.pump();
    // アニメーションの途中（ウィジェットの再構築は起きない）
    await tester.pump(const Duration(milliseconds: 150));
    var panel = tester.getRect(find.byKey(const Key('panel')));
    var ctrl = tester.getRect(find.byKey(const Key('ctrl')));
    expect(ctrl.height, greaterThan(200));
    expect(ctrl.height, lessThan(320));
    expect(panel.bottom, closeTo(ctrl.top, 0.5),
        reason: '以前は測った高さが更新されず、コントローラーに重なっていた');

    await tester.pumpAndSettle();
    panel = tester.getRect(find.byKey(const Key('panel')));
    ctrl = tester.getRect(find.byKey(const Key('ctrl')));
    expect(ctrl.height, closeTo(320, 0.5));
    expect(panel.bottom, closeTo(ctrl.top, 0.5));
  });
}
