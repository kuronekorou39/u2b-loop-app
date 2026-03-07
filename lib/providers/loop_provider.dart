import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/loop_state.dart';
import 'player_provider.dart';

final loopProvider = StateNotifierProvider<LoopNotifier, LoopState>((ref) {
  return LoopNotifier(ref);
});

class LoopNotifier extends StateNotifier<LoopState> {
  final Ref _ref;
  Timer? _timer;

  LoopNotifier(this._ref) : super(const LoopState()) {
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _checkLoop(),
    );
  }

  void _checkLoop() {
    if (!state.enabled || state.isInGap) return;
    if (state.pointB <= Duration.zero) return;

    final player = _ref.read(playerProvider);
    final position = player.state.position;

    if (position >= state.pointB) {
      if (state.gapSeconds > 0) {
        state = state.copyWith(isInGap: true);
        player.pause();
        Future.delayed(
          Duration(milliseconds: (state.gapSeconds * 1000).round()),
          () {
            if (!mounted) return;
            player.seek(state.pointA);
            player.play();
            state = state.copyWith(isInGap: false);
          },
        );
      } else {
        player.seek(state.pointA);
      }
    }
  }

  void setPointA(Duration d) => state = state.copyWith(pointA: d);
  void setPointB(Duration d) => state = state.copyWith(pointB: d);

  void setPointAToCurrentPosition() {
    final pos = _ref.read(playerProvider).state.position;
    state = state.copyWith(pointA: pos);
  }

  void setPointBToCurrentPosition() {
    final pos = _ref.read(playerProvider).state.position;
    state = state.copyWith(pointB: pos);
  }

  void toggleEnabled() => state = state.copyWith(enabled: !state.enabled);

  void setGap(double seconds) =>
      state = state.copyWith(gapSeconds: seconds.clamp(0, 10));

  void setStep(double seconds) => state = state.copyWith(adjustStep: seconds);

  void adjustPointA(int direction) {
    final stepMs = (state.adjustStep * 1000).round();
    final newA = state.pointA + Duration(milliseconds: stepMs * direction);
    if (newA >= Duration.zero) {
      state = state.copyWith(pointA: newA);
    }
  }

  void adjustPointB(int direction) {
    final stepMs = (state.adjustStep * 1000).round();
    final newB = state.pointB + Duration(milliseconds: stepMs * direction);
    if (newB >= Duration.zero) {
      state = state.copyWith(pointB: newB);
    }
  }

  void reset() => state = const LoopState();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
