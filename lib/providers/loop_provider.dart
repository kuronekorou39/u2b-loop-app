import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/loop_item.dart';
import '../models/loop_state.dart';
import 'player_provider.dart';
import '../core/loop/region_sequence.dart';
import '../core/storage/app_boxes.dart';
import 'data_provider.dart';

/// 単体再生で選んでいる区間。-1 は「全体」。
/// ミニプレイヤーの間は再生画面が無いので、画面ではなくここで持つ
final activeRegionIndexProvider = StateProvider<int>((ref) => -1);

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

  /// これより短い曲末の無音は飛ばさない（曲の余韻や区切りのうち）
  static const minSilenceSkip = Duration(seconds: 1);

  /// 曲の後の無音が始まる位置。飛ばすほどの無音が無ければ null
  static Duration? silenceSkipAt(Duration duration, int? trailingSilenceMs) {
    if (trailingSilenceMs == null) return null;
    final silence = Duration(milliseconds: trailingSilenceMs);
    if (silence < minSilenceSkip || silence >= duration) return null;
    return duration - silence;
  }

  /// 無音を飛ばして次へ進めた曲（読み込みの間に同じ曲でもう一度進めないように）
  String? _silenceSkippedId;

  /// DJ なしで「曲の後の無音を飛ばす」がオンのときの飛ばす位置
  Duration? _silenceSkipPoint(Duration duration) {
    final id = currentItemId;
    if (id == null ||
        !_ref.read(skipTrailingSilenceProvider) ||
        _ref.read(crossfadeProvider) != 0) {
      return null;
    }
    return silenceSkipAt(duration, AppBoxes.loopItems.get(id)?.trailingSilenceMs);
  }

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
      if (_advanceChain()) return;
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
      final silentFrom =
          duration > Duration.zero ? _silenceSkipPoint(duration) : null;
      if (silentFrom != null) {
        if (position < silentFrom) {
          _silenceSkippedId = null;
        } else if (_silenceSkippedId != currentItemId) {
          _silenceSkippedId = currentItemId;
          onTrackEnd!();
          return;
        }
      }
    }

    if (!state.enabled || state.isInGap) return;
    final b = state.pointB;
    if (b == null) return;

    final a = state.pointA ?? Duration.zero;

    // A >= B の場合はループ不可（逆転・同一地点）
    if (a >= b) return;

    // B地点の手前に戻ったらガードをリセット（短い区間は区間の半分まで）
    final guardMs = min(500, (b - a).inMilliseconds ~/ 2);
    if (position < b - Duration(milliseconds: guardMs)) {
      _bPointHandled = false;
    }

    if (position >= b) {
      if (_advanceChain()) return;
      // プレイリストモードのコールバック（二重実行ガード付き）
      if (!_bPointHandled && onBPointReached != null && onBPointReached!()) {
        _bPointHandled = true;
        return; // コールバックが処理済み
      }
      if (_bPointHandled) return; // 既にコールバック処理済み

      _jumpTo(a);
    }
  }

  /// [a] へ戻る・進む（ループの間があれば止めて待ってから）
  void _jumpTo(Duration a) {
    final player = _ref.read(playerProvider);
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
      player.play();
    }
  }

  /// 連続再生: 次の区間へ進む。進んだら true（画面が無いミニプレイヤー中も同じ）
  bool _advanceChain() {
    if (!state.chainRegions || _bPointHandled) return false;
    final id = currentItemId;
    if (id == null) return false;
    final regions = AppBoxes.loopItems.get(id)?.effectiveRegions;
    if (regions == null) return false;
    final current = _ref.read(activeRegionIndexProvider);
    final next = RegionSequence.nextIndex(regions, current);
    if (next == null || next == current) return false;
    final a = Duration(milliseconds: regions[next].pointAMs!);
    final b = Duration(milliseconds: regions[next].pointBMs!);
    _bPointHandled = true;
    _ref.read(activeRegionIndexProvider.notifier).state = next;
    state = state.copyWith(pointA: () => a, pointB: () => b);
    _jumpTo(a);
    return true;
  }

  void setChainRegions(bool on) => state = state.copyWith(chainRegions: on);

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

  /// ループを切ると連続再生も終わる（B で次へ進むのはループ中だけ）
  void toggleEnabled() => state = state.copyWith(
      enabled: !state.enabled,
      chainRegions: state.enabled ? false : state.chainRegions);

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
