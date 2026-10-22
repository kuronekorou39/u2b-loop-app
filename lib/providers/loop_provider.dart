import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/loop_item.dart';
import '../models/loop_state.dart';
import 'player_provider.dart';
import '../core/storage/app_boxes.dart';
import 'data_provider.dart';
import '../core/audio/beat_grid.dart';

/// シークバーに出している曲の ID（拍の線の表示用）。再生画面・ミニプレイヤーは
/// [LoopNotifier.setCurrentItem] で、AB 設定画面は開いたときに入れる
final seekbarItemIdProvider = StateProvider<String?>((ref) => null);

/// シークバーの波形に引く拍の線の材料（格子と、小節頭の代わりの基準 = ドロップ）。
/// 表示オフ・格子が無い・信用できない曲は null
final seekbarBeatsProvider =
    Provider<BeatLineSource?>((ref) {
  if (!ref.watch(showBeatLinesProvider)) return null;
  final id = ref.watch(seekbarItemIdProvider);
  if (id == null) return null;
  return ref
      .watch(loopItemsProvider)
      .where((i) => i.id == id)
      .firstOrNull
      ?.beatLines;
});

final loopProvider = StateNotifierProvider<LoopNotifier, LoopState>((ref) {
  final notifier = LoopNotifier(ref);
  // アクティブスロットの切替に追従して completed 購読を自動で張り替える。
  // （手動で relistenCompleted() を呼ぶ方式は呼び忘れで購読が死ぬため廃止）
  ref.listen(activeSlotProvider, (_, _) => notifier.relistenCompleted());
  return notifier;
});

class LoopNotifier extends StateNotifier<LoopState> {
  final Ref _ref;
  Timer? _timer;
  StreamSubscription? _completedSub;

  /// 外部からの読み取り用
  LoopState get currentState => state;

  /// B地点到達時のコールバック。設定されていればループの代わりに呼ばれる。
  /// 戻り値 true = 処理済み（ループしない）、false = 通常のABループを実行
  bool Function()? onBPointReached;

  /// onBPointReached の二重実行を防ぐガードフラグ
  bool _bPointHandled = false;

  /// 動画終了検知用コールバック（ABループなし時、動画が終端に達した場合）
  VoidCallback? onTrackEnd;

  /// 曲終了を終端のこれだけ手前で発火する（completed を待つと次曲の開始が遅れる）。
  /// クロスフェードの曲線はこの時点で 0 に着くように作る（PlaylistEngine）
  static const trackEndLead = Duration(milliseconds: 500);

  /// 現在再生中のアイテムID（再生カウント用、外部からセット）
  String? currentItemId;

  /// 再生カウントの保存間隔管理
  int _playCountAccMs = 0;
  static const _playCountSaveInterval = 5000; // 5秒ごとにHive保存
  int _msSinceLastSave = 0;

  LoopNotifier(this._ref) : super(const LoopState()) {
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        _checkLoop();
        _trackPlayTime();
      },
    );
    _listenCompleted();
  }

  /// player.stream.completed を直接listenして曲終了を確実に検知
  void _listenCompleted() {
    _completedSub?.cancel();
    final player = _ref.read(playerProvider);
    _completedSub = player.stream.completed.listen((completed) {
      if (!completed) return;
      if (!mounted) return;
      debugPrint('[LoopNotifier] completed event');
      _handleTrackCompleted();
    });
  }

  /// 曲が自然終了した時の処理
  void _handleTrackCompleted() {
    final player = _ref.read(playerProvider);
    // ABループが有効ならA点にシーク。B 点が終端と同じで _checkLoop が間に合わなかった
    // ときも、プレイリストの判断（次へ進む・終わりで止める）を先に通す
    if (state.enabled && state.pointA != null) {
      if (!_bPointHandled && onBPointReached != null && onBPointReached!()) {
        _bPointHandled = true;
        return;
      }
      if (_bPointHandled) return;
      player.seek(state.pointA ?? Duration.zero);
      player.play();
      return;
    }
    // プレイリストモード: onTrackEndコールバック
    if (onTrackEnd != null) {
      onTrackEnd!();
      return;
    }
  }

  /// activeSlot変更時にストリームを再リッスン（loopProviderのref.listenから自動で呼ばれる）
  void relistenCompleted() {
    _listenCompleted();
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
      if (duration > Duration.zero && position >= duration - trackEndLead) {
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

  /// 曲の長さを保存済みのアイテム ID
  String? _durationSavedFor;

  /// 再生時間を累積し、しきい値到達で再生回数をインクリメント
  void _trackPlayTime() {
    final player = _ref.read(playerProvider);
    if (!player.state.playing) return;
    if (currentItemId == null) return;

    final durationMs = player.state.duration.inMilliseconds;
    if (durationMs <= 0) return;

    // 曲の長さは再生が始まって初めて分かる。曲ごとに 1 回だけ覚えておく（解析の要否に使う）
    if (_durationSavedFor != currentItemId) {
      _durationSavedFor = currentItemId;
      _ref.read(loopItemsProvider.notifier).saveDuration(currentItemId!, durationMs);
    }

    _playCountAccMs += 100;
    _msSinceLastSave += 100;

    final threshold = LoopItem.playCountThresholdMs(durationMs);
    if (_playCountAccMs < threshold) {
      // しきい値未達でも定期保存（アプリ終了対策）
      if (_msSinceLastSave >= _playCountSaveInterval) {
        _saveAccumulatedTime();
      }
      return;
    }

    // しきい値到達 → カウント+1
    _playCountAccMs -= threshold;
    _ref
        .read(loopItemsProvider.notifier)
        .incrementPlayCount(currentItemId!, _playCountAccMs);
    _msSinceLastSave = 0;
  }

  void _saveAccumulatedTime() {
    if (currentItemId == null) return;
    _ref
        .read(loopItemsProvider.notifier)
        .saveAccumulatedPlayMs(currentItemId!, _playCountAccMs);
    _msSinceLastSave = 0;
  }

  /// トラック切替時に呼ぶ: 累積時間をアイテムから復元
  void setCurrentItem(String? itemId) {
    // 前のアイテムの累積を保存
    if (currentItemId != null && currentItemId != itemId) {
      _saveAccumulatedTime();
    }
    currentItemId = itemId;
    _ref.read(seekbarItemIdProvider.notifier).state = itemId;
    _msSinceLastSave = 0;
    if (itemId != null) {
      final box = AppBoxes.loopItems;
      final item = box.get(itemId);
      _playCountAccMs = item?.accumulatedPlayMs ?? 0;
    } else {
      _playCountAccMs = 0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _completedSub?.cancel();
    _saveAccumulatedTime();
    super.dispose();
  }
}
