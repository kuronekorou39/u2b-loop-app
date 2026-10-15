import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/playback/load_progress.dart';

/// 読み込み画面の進捗。段階が一瞬で飛ばないこと、Tip が begin〜end の間だけ
/// 切り替わることを確かめる（再生画面と AB 設定画面の両方がこれを使う）
void main() {
  test('step は前の段階から minStep 空けてから進む', () async {
    final p = LoadProgress(minStep: const Duration(milliseconds: 80));
    p.begin();
    final sw = Stopwatch()..start();
    await p.step(0.5, 'a');
    await p.step(1.0, 'b');
    sw.stop();
    expect(p.progress.value, 1.0);
    expect(p.status.value, 'b');
    // begin → a → b で 2 段階ぶん
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
    p.dispose();
  });

  test('begin で 0 と「準備中...」に戻る', () async {
    final p = LoadProgress(minStep: Duration.zero);
    p.begin();
    await p.step(0.9, 'x');
    p.begin();
    expect(p.progress.value, 0);
    expect(p.status.value, LoadProgress.initialStatus);
    p.dispose();
  });

  test('Tip は begin で切り替わり、end で止まる', () async {
    var n = 0;
    final p = LoadProgress(
      minStep: Duration.zero,
      tipInterval: const Duration(milliseconds: 20),
      nextTip: () => 'tip${n++}',
    );
    expect(p.tip.value, 'tip0');
    p.begin();
    expect(p.tip.value, 'tip1');
    await Future.delayed(const Duration(milliseconds: 70));
    expect(n, greaterThanOrEqualTo(3));
    p.end();
    final atEnd = n;
    await Future.delayed(const Duration(milliseconds: 70));
    expect(n, atEnd);
    p.dispose();
  });

  test('dispose 後の step は何もしない（タイマー越しの遅延呼び出し対策）', () async {
    final p = LoadProgress(minStep: const Duration(milliseconds: 30));
    p.begin();
    final pending = p.step(0.5, 'late');
    p.dispose();
    await pending; // ValueNotifier が dispose 済みでも落ちない
  });
}
