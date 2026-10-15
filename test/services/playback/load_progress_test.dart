import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/playback/load_progress.dart';

/// 曲を開いている間の進捗（再生画面と AB 設定画面の動画枠に出す）
void main() {
  test('step で進捗と文言が変わる', () {
    final p = LoadProgress();
    p.begin();
    p.step(0.5, 'a');
    p.step(1.0, 'b');
    expect(p.progress.value, 1.0);
    expect(p.status.value, 'b');
    p.dispose();
  });

  test('begin で 0 と「準備中...」に戻る', () {
    final p = LoadProgress();
    p.begin();
    p.step(0.9, 'x');
    p.begin();
    expect(p.progress.value, 0);
    expect(p.status.value, LoadProgress.initialStatus);
    p.dispose();
  });

  test('dispose 後の step は何もしない（画面を離れた後に届いても落ちない）', () {
    final p = LoadProgress();
    p.dispose();
    p.step(0.5, 'late');
    p.begin();
  });
}
