import 'dart:async';
import 'dart:ui' show VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/loop_state.dart';
import 'player_provider.dart';

final loopProvider = StateNotifierProvider<LoopNotifier, LoopState>((ref) {
  return LoopNotifier(ref);
});

class LoopNotifier extends StateNotifier<LoopState> {
  final Ref _ref;
  Timer? _timer;

  /// B地点到達時のコールバック。設定されていればループの代わりに呼ばれる。
  /// 戻り値 true = 処理済み（ループしない）、false = 通常のABループを実行
  bool Function()? onBPointReached;

  /// onBPointReached の二重実行を防ぐガードフラグ
  bool _bPointHandled = false;

  /// 動画終了検知用コールバック（ABループなし時、動画が終端に達した場合）
  VoidCallback? onTrackEnd;

  LoopNotifier(this._ref) : super(const LoopState()) {
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _checkLoop(),
    );
  }

  Duration get _maxDuration => _ref.read(playerProvider).state.duration;

  Duration _clamp(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    final max = _maxDuration;
    if (max > Duration.zero && d > max) return max;
    return d;
  }

  void _checkLoop() {
    final player = _ref.read(playerProvider);
    if (!player.state.playing) return; // 再生中でなければスキップ

    final position = player.state.position;
    final duration = player.state.duration;

    // 動画終了検知（ABループが無効、かつ動画終端付近）
    if (!state.enabled && onTrackEnd != null) {
      if (duration > Duration.zero &&
          position >= duration - const Duration(milliseconds: 500)) {
        onTrackEnd!();
        return;
      }
    }

    if (!state.enabled || state.isInGap) return;
    final b = state.pointB;
    if (b == null) return;

    final a = state.pointA ?? Duration.zero;

    // A >= B の場合はループ不可（逆転・同一地点）
    if (a >= b) return;

    // B地点の500ms以上手前ならガードをリセット
    if (position < b - const Duration(milliseconds: 500)) {
      _bPointHandled = false;
    }

    if (position >= b) {
      // プレイリストモードのコールバック（二重実行ガード付き）
      if (!_bPointHandled && onBPointReached != null && onBPointReached!()) {
        _bPointHandled = true;
        return; // コールバックが処理済み
      }
      if (_bPointHandled) return; // 既にコールバック処理済み

      if (state.gapSeconds > 0) {
        state = state.copyWith(isInGap: true);
        player.pause();
        Future.delayed(
          Duration(milliseconds: (state.gapSeconds * 1000).round()),
          () {
            if (!mounted) return;
            player.seek(a);
            player.play();
            state = state.copyWith(isInGap: false);
          },
        );
      } else {
        player.seek(a);
      }
    }
  }

  void setPointA(Duration? d) =>
      state = state.copyWith(pointA: () => d != null ? _clamp(d) : null);
  void setPointB(Duration? d) =>
      state = state.copyWith(pointB: () => d != null ? _clamp(d) : null);

  void setPointAToCurrentPosition() {
    final pos = _ref.read(playerProvider).state.position;
    state = state.copyWith(pointA: () => pos);
  }

  void setPointBToCurrentPosition() {
    final pos = _ref.read(playerProvider).state.position;
    state = state.copyWith(pointB: () => pos);
  }

  void toggleEnabled() => state = state.copyWith(enabled: !state.enabled);

  void setGap(double seconds) =>
      state = state.copyWith(gapSeconds: seconds.clamp(0, 10));

  void setStep(double seconds) => state = state.copyWith(adjustStep: seconds);

  void adjustPointA(int direction) {
    final a = state.pointA;
    if (a == null) return;
    final stepMs = (state.adjustStep * 1000).round();
    final newA = _clamp(a + Duration(milliseconds: stepMs * direction));
    state = state.copyWith(pointA: () => newA);
  }

  void adjustPointB(int direction) {
    final b = state.pointB;
    if (b == null) return;
    final stepMs = (state.adjustStep * 1000).round();
    final newB = _clamp(b + Duration(milliseconds: stepMs * direction));
    state = state.copyWith(pointB: () => newB);
  }

  void swapPoints() {
    state = state.copyWith(
      pointA: () => state.pointB,
      pointB: () => state.pointA,
    );
  }

  void reset() {
    _bPointHandled = false;
    final step = state.adjustStep;
    state = LoopState(adjustStep: step);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
