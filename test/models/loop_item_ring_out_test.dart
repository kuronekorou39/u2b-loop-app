import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

LoopItem _item({int? trailing, int? tail, int? shared}) => LoopItem(
      id: 'i',
      title: 't',
      uri: '',
      sourceType: SourceTypes.youtube,
      trailingSilenceMs: trailing,
      musicTailMs: tail,
      sharedTailMs: shared,
    );

/// 拍が取れなくなった後の短い一節は曲の一部として残す（Snow の最後の「ずっと消えない」）
void main() {
  test('無音の手前 10 秒以内は最後の一節なので飛ばさない', () {
    final i = _item(trailing: 19250, tail: 24707);
    expect(i.outroSkipMs, 19250);
    expect(i.bodyOutroSkipMs, 24707);
  });

  test('それより長い部分はトークとして飛ばす', () {
    expect(_item(trailing: 1000, tail: 30000).outroSkipMs, 30000);
  });

  test('ほかの曲と共通の端は最後の一節でも飛ばす', () {
    expect(_item(trailing: 19000, tail: 24000, shared: 26000).outroSkipMs, 26000);
  });
}
