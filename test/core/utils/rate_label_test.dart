import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/rate_label.dart';

/// 再生速度の表示は小数 2 桁まで（DJ のテンポ合わせで端数が出ても崩れない）
void main() {
  test('端数は 2 桁に丸め、末尾の 0 は省く。1 倍は 1.0x', () {
    expect(rateLabel(1.00000044), '1.0x');
    expect(rateLabel(1.0), '1.0x');
    expect(rateLabel(1.25), '1.25x');
    expect(rateLabel(0.5), '0.5x');
    expect(rateLabel(1.0234), '1.02x');
    expect(rateLabel(0.9966), '1.0x');
    expect(rateLabel(2), '2.0x');
  });

  test('候補の速度と同じかは 2 桁で比べる', () {
    expect(sameRate(1.0, 1.00000044), isTrue);
    expect(sameRate(1.25, 1.0), isFalse);
  });
}
