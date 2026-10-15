import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/player_wide_top_bar.dart';

/// 横レイアウトの topBar（再生画面と AB 設定画面で共用）: 戻る・題・操作
void main() {
  testWidgets('戻るで前の画面に戻り、題と操作が並ぶ', (tester) async {
    var popped = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              body: PlayerWideTopBar(
                title: 'AB 設定',
                actions: [
                  IconButton(
                      icon: const Icon(Icons.save),
                      tooltip: '保存',
                      onPressed: () {}),
                ],
              ),
            ),
          )).then((_) => popped = true),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('AB 設定'), findsOneWidget);
    expect(find.byTooltip('保存'), findsOneWidget);
    await tester.tap(find.byTooltip('戻る'));
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect(find.text('AB 設定'), findsNothing);
  });
}
