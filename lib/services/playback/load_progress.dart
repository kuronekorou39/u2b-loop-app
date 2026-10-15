import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/tips.dart';

/// 読み込み画面の進捗（バー・状態文・Tip）。
///
/// それぞれ ValueNotifier なので PlayerLoadingView が画面全体を描き直さずに済む。
/// [step] は前の段階から [minStep] だけ間を空ける（段階が一瞬で飛ぶとバーが
/// 動いて見えないため）。Tip は [begin] から [end] まで [tipInterval] ごとに切り替わる
class LoadProgress {
  LoadProgress({
    this.minStep = const Duration(milliseconds: 300),
    this.tipInterval = const Duration(seconds: 8),
    String Function()? nextTip,
  })  : _nextTip = nextTip ?? getRandomTip,
        tip = ValueNotifier<String>((nextTip ?? getRandomTip)());

  static const initialStatus = '準備中...';

  final progress = ValueNotifier<double>(0);
  final status = ValueNotifier<String>(initialStatus);
  final ValueNotifier<String> tip;

  final Duration minStep;
  final Duration tipInterval;
  final String Function() _nextTip;

  DateTime _lastStep = DateTime.now();
  Timer? _tipTimer;
  bool _disposed = false;

  /// 読み込みの始まり: 0 に戻し、Tip の切り替えを始める
  void begin() {
    if (_disposed) return;
    progress.value = 0;
    status.value = initialStatus;
    _lastStep = DateTime.now();
    tip.value = _nextTip();
    _tipTimer?.cancel();
    _tipTimer = Timer.periodic(tipInterval, (_) {
      if (!_disposed) tip.value = _nextTip();
    });
  }

  /// 次の段階へ。前の段階から [minStep] 経っていなければその分待つ
  Future<void> step(double value, String text) async {
    final elapsed = DateTime.now().difference(_lastStep);
    if (elapsed < minStep) {
      await Future.delayed(minStep - elapsed);
    }
    if (_disposed) return;
    _lastStep = DateTime.now();
    progress.value = value;
    status.value = text;
  }

  /// 読み込みの終わり（成功でも失敗でも）: Tip の切り替えを止める
  void end() {
    _tipTimer?.cancel();
    _tipTimer = null;
  }

  void dispose() {
    _disposed = true;
    end();
    progress.dispose();
    status.dispose();
    tip.dispose();
  }
}
