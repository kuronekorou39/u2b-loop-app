import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/build_flavor.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/services/save_flow.dart';

// ふつうは全部入りで走る。`--dart-define=STORE_BUILD=true` を付けるとストア用の確認になる
void main() {
  LoopItem item(String sourceType) => LoopItem(
      id: sourceType, title: 't', uri: 'u', sourceType: sourceType);

  test('ストア用だけ YouTube の曲の保存・書き出しを出さない', () {
    expect(SaveFlow.canSave(item(SourceTypes.youtube)), !BuildFlavor.store);
  });

  test('ローカルの曲はどちらのビルドでも書き出せる', () {
    expect(SaveFlow.canSave(item(SourceTypes.local)), isTrue);
  });
}
