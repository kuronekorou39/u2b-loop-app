import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:u2b_loop_app/core/constants.dart';
import 'package:u2b_loop_app/core/ui/app_sheets.dart';
import 'package:u2b_loop_app/core/ui/app_snack_bar.dart';
import 'package:u2b_loop_app/widgets/player/more_tile.dart';
import 'package:u2b_loop_app/widgets/share_playlist_popup.dart';

/// プレイリストの共有: 下のシートではなく真ん中のポップアップ。QR は横画面でも全体が入る
void main() {
  const url = 'u2bloop://share/abc';

  Future<void> open(WidgetTester tester,
      {Size size = const Size(360, 640), String link = url}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => SharePlaylistPopup.show(context,
                name: 'ソニックR', songCount: 8, url: link),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
  }

  MoreTile tile(WidgetTester tester, String label) => tester.widget<MoreTile>(
      find.ancestor(of: find.text(label), matching: find.byType(MoreTile)));

  for (final size in [const Size(360, 640), const Size(800, 360)]) {
    testWidgets('真ん中に出て、3 つのボタンが 1 行に並ぶ（$size）', (tester) async {
      await open(tester, size: size);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(SheetDialog), findsOneWidget);
      expect(find.text('ソニックR'), findsOneWidget);
      expect(find.text('8 曲'), findsOneWidget);
      final tops = ['送る', 'コピー', 'QR コード']
          .map((l) => tester.getTopLeft(find.ancestor(
              of: find.text(l), matching: find.byType(MoreTile))).dy)
          .toSet();
      expect(tops, hasLength(1));
    });
  }

  testWidgets('コピーはリンクをクリップボードに入れて閉じる', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await tester.tap(find.text('コピー'));
    await tester.pumpAndSettle();
    expect(copied, url);
    expect(find.byType(SheetDialog), findsNothing);
    AppToast.instance.hide();
    await tester.pump(const Duration(seconds: 3));
  });

  for (final size in [const Size(360, 640), const Size(800, 360)]) {
    testWidgets('QR は共有のポップアップと入れ替わり、全体が画面に入る（$size）', (tester) async {
      await open(tester, size: size);
      await tester.tap(find.text('QR コード'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MoreTile), findsNothing);
      final qr = tester.getRect(find.byType(QrImageView));
      expect(qr.width, closeTo(qr.height, 0.5));
      expect(qr.width, greaterThanOrEqualTo(220));
      expect(qr.top, greaterThanOrEqualTo(0));
      expect(qr.bottom, lessThanOrEqualTo(size.height));
    });
  }

  testWidgets('QR にできない長さは QR だけ押せない（場所は残す）', (tester) async {
    await open(tester, link: 'u2bloop://share/${'a' * AppLimits.qrMaxLength}');
    expect(tile(tester, 'QR コード').enabled, isFalse);
    expect(tile(tester, '送る').enabled, isTrue);
    expect(tile(tester, 'コピー').enabled, isTrue);
  });
}
