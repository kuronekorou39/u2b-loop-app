import 'package:flutter/foundation.dart';

/// 曲を開いている間の進捗と状態の文言。
/// それぞれ ValueNotifier なので、動画枠の読み込み表示（PlayerLoadingStage）だけを
/// 描き直せる。以前は専用の読み込み画面と Tip があったが、v1.92.0 で再生画面に
/// 直接入る形にしたので、残るのは進捗バーと一行の文言だけ
class LoadProgress {
  static const initialStatus = '準備中...';

  final progress = ValueNotifier<double>(0);
  final status = ValueNotifier<String>(initialStatus);

  bool _disposed = false;

  void begin() {
    if (_disposed) return;
    progress.value = 0;
    status.value = initialStatus;
  }

  void step(double value, String text) {
    if (_disposed) return;
    progress.value = value;
    status.value = text;
  }

  /// 以前は Tip の切り替えを止めていた。今は何もしないが、呼び出し側の手順は変えない
  void end() {}

  void dispose() {
    _disposed = true;
    progress.dispose();
    status.dispose();
  }
}
