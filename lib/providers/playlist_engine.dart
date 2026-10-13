import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/audio/track_compatibility.dart';
import '../models/loop_item.dart';
import '../models/playlist_mode.dart';
import '../models/playlist_track.dart';
import '../services/cache_service.dart';
import '../services/youtube_service.dart';
import 'loop_provider.dart';
import 'player_provider.dart';
import 'playlist_player_provider.dart';

final playlistEngineProvider =
    Provider<PlaylistEngine>((ref) => PlaylistEngine(ref));

/// クロスフェードの進捗（0〜1）と、鳴り始めている次曲。交差していないときは null。
/// 画面の遷移演出（動画が引いて次曲サムネが出る）がこれを見て描く
final crossfadeProgressProvider =
    StateProvider<({double progress, LoopItem next})?>((ref) => null);

/// 次トラックへ進めるかの判定結果。
enum AdvanceReadiness {
  /// 同一アイテムの別区間 → シークだけで移れる（ロード不要）
  sameItem,

  /// 別アイテムだがプリロード済み → スワップで即座に移れる
  preloaded,

  /// 未準備 → ロードが必要（呼び出し側がローディング表示 or ループ継続を選ぶ）
  notReady,

  /// 次トラックが無い（プレイリスト終端かつリピートなし）
  none,
}

/// プレイリスト遷移の「機構」を1箇所に集約したもの。
///
/// 以前は PlayerScreen 用とミニプレイヤー用に遷移処理が2重実装されており、
/// 「旧プレイヤーを止め忘れて二重再生」「前曲の再生速度が残る」
/// 「オフライン保存済み動画がミニプレイヤーで再生できず次曲に進めない」など、
/// 片方にだけ修正が入る形の不具合が繰り返し発生していた。
///
/// 画面の有無で変わらない部分（URL解決・プリロード・スロット入替・遷移可否判定）を
/// ここに置き、画面固有の演出（ローディング表示・波形・字幕・フェード）だけを
/// 呼び出し側に残す。
class PlaylistEngine {
  PlaylistEngine(this._ref);

  final Ref _ref;

  /// 現在のアクティブプレイヤー（再生中の側）。
  Player get activePlayer => _ref.read(playerProvider);

  /// 現在のプリロード用プレイヤー（非アクティブ側）。
  Player get preloadPlayer => _ref.read(preloadPlayerProvider);

  // --- URL解決 ---

  /// 再生対象のURIを解決する。
  /// オフライン保存済みならローカルファイルを優先し、通信を一切行わない。
  /// YouTubeで解決できない場合は null（呼び出し側が次の手段を選ぶ）。
  Future<String?> resolvePlayableUri(LoopItem item) async {
    final cached = CacheService.offlineVideoPath(item);
    if (cached != null) return cached;
    if (!item.isYouTube || item.videoId == null) {
      return item.uri.isEmpty ? null : item.uri;
    }
    try {
      return await _ref.read(youtubeServiceProvider).resolveStreamUrl(item.videoId!);
    } catch (e) {
      debugPrint('[PlaylistEngine] URL解決に失敗: $e');
      return null;
    }
  }

  // --- プリロード / ロードの共通機構 ---

  /// [player] に [track] を読み込んで再生準備を整える。
  ///
  /// - オフライン保存済みならローカルファイルを使う（通信なし・即時）
  /// - duration が取れない場合は無音で短く再生してメタデータを確定させる
  ///   （duration=0 のままだとループ監視も終端検知も働かない）
  /// - 開始位置へシークし、**毎回**速度を設定する
  ///   （プレイヤーを2枚使い回す設計のため、設定しないと前曲の速度が残る）
  ///
  /// [isStale] が true を返した時点で処理を打ち切る（曲を素早く切り替えた際のレース対策）。
  /// 戻り値は YouTube のマニフェスト（波形の先行生成に再利用するため）。
  /// キャッシュ再生・ローカルファイルの場合は null。
  Future<StreamManifest?> prepare(
    Player player,
    PlaylistTrack track, {
    bool Function()? isStale,
    bool waitForMetadata = true,
  }) async {
    bool stale() => isStale?.call() ?? false;
    final item = track.item;

    // どちらのプレイヤーを読み直す場合も、進行中のクロスフェードは成立しなくなる
    disarmCrossfade();
    // 読み直す側がテンポを戻している途中なら、その速度を上書きされないよう止める
    if (identical(player, _tempoRampPlayer)) _cancelTempoRamp();

    StreamManifest? manifest;
    final cached = CacheService.offlineVideoPath(item);
    if (cached != null) {
      await player.open(Media(cached), play: false);
    } else if (item.isYouTube && item.videoId != null) {
      final ytService = _ref.read(youtubeServiceProvider);
      manifest = await ytService.getManifestWithFallback(item.videoId!);
      if (stale()) return null;
      await player.open(Media(YouTubeService.pickStreamUrl(manifest)), play: false);
    } else {
      await player.open(Media(item.uri), play: false);
    }
    if (stale()) return manifest;

    if (waitForMetadata && player.state.duration == Duration.zero) {
      final restoreVolume = _ref.read(playerProvider).state.volume;
      await player.setVolume(0);
      await player.play();
      for (var i = 0;
          i < 30 && player.state.duration == Duration.zero && !stale();
          i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await player.pause();
      await player.setVolume(restoreVolume);
      if (stale()) return manifest;
    }

    await player.seek(effectiveStart(track));
    await player.setRate(item.speed);
    return manifest;
  }

  /// トラックの再生開始位置。区間があればA点。
  /// 無ければ、クロスフェード有効時は曲頭の無音を飛ばす（無音同士を重ねない）
  Duration effectiveStart(PlaylistTrack track) {
    final startMs = track.startMs;
    if (startMs != null) return Duration(milliseconds: startMs);
    if (crossfadeDuration == Duration.zero) return Duration.zero;
    return Duration(milliseconds: track.item.leadingSilenceMs ?? 0);
  }

  // --- スロット入替 ---

  /// アクティブスロットを入れ替え、プリロード済みプレイヤーの再生を開始する。
  ///
  /// 旧プレイヤーは**必ず** stop する。省くと、次のプリロードが旧プレイヤーを
  /// 再openするまで（次曲が無ければ永久に）二重再生になる。
  /// completed購読の張り替えは activeSlotProvider の変化に追従して
  /// LoopNotifier が自動で行うため、ここでは呼ばない。
  ///
  /// 戻り値は新しくアクティブになったプレイヤー。
  Player swapSlots() {
    final oldPlayer = _ref.read(playerProvider);
    final newSlot =
        _ref.read(activeSlotProvider) == ActiveSlot.a ? ActiveSlot.b : ActiveSlot.a;
    _ref.read(activeSlotProvider.notifier).state = newSlot;

    // プロバイダ経由だと同一フレーム内で更新が反映されない場合があるため直接参照する
    final newPlayer = newSlot == ActiveSlot.a
        ? _ref.read(playerAProvider)
        : _ref.read(playerBProvider);

    // 交差中ならここで完了させる。監視は止める（次のプリロードで再び arm される）
    final session = _crossfade;
    _crossfade = null;
    _armedTrack = null;
    _crossfadeMonitor?.cancel();
    _crossfadeMonitor = null;
    _ref.read(crossfadeProgressProvider.notifier).state = null;

    oldPlayer.stop();
    session?.finish();
    newPlayer.play();
    // テンポを寄せていたなら、前曲が消えた後にゆっくり本来の速度へ戻す
    if (session != null && session.inRate != session.inBaseRate) {
      _startTempoRamp(session.inPlayer, session.inRate, session.inBaseRate);
    }
    return newPlayer;
  }

  // --- クロスフェード ---
  //
  // プリロード済みの次曲を切断点（B点 or 終端）の数秒前から鳴らし始め、
  // 等パワー曲線で音量を交差させる。切断点に達すると従来どおり swapSlots() が
  // 呼ばれ、そこで交差を完了する（新プレイヤーは既に再生中なので play し直すだけ）。
  // 監視タイマーはプリロード完了〜スワップの間だけ動く。

  Timer? _crossfadeMonitor;
  PlaylistTrack? _armedTrack;
  _CrossfadeSession? _crossfade;

  /// 交差中か。画面側はこの間、旧プレイヤーの音量を触らないこと
  bool get isCrossfading => _crossfade != null;

  Duration get crossfadeDuration =>
      Duration(seconds: _ref.read(crossfadeProvider));

  /// 次曲のプリロードが完了したら呼ぶ。切断点の手前で自動的に交差を始める
  void armCrossfade(PlaylistTrack next) {
    _armedTrack = next;
    _crossfadeMonitor ??= Timer.periodic(
        const Duration(milliseconds: 100), (_) => _crossfadeTick());
  }

  /// プリロードが無効になったら呼ぶ（キャンセル・取り直し・読み直し）。進行中なら取り消す
  void disarmCrossfade() {
    _armedTrack = null;
    _crossfadeMonitor?.cancel();
    _crossfadeMonitor = null;
    _cancelCrossfade();
  }

  /// 曲末の無音をこれより多く飛ばすときだけ、曲末を待たずに自分で遷移を起こす
  /// （LoopNotifier は終端の 500ms 手前で onTrackEnd を呼ぶので、それ未満なら任せる）
  static const _minSilenceCut = Duration(milliseconds: 500);

  /// 切断点。ABループ有効ならB点。なければ曲末の無音を除いた位置、不明なら曲の終端。
  /// [advancesAtCut] は、終端より手前で切るため遷移をこちらから起こす必要があるか
  ({Duration cut, bool advancesAtCut})? _cutPoint() {
    final ls = _ref.read(loopProvider);
    final b = ls.pointB;
    if (ls.enabled && b != null && (ls.pointA ?? Duration.zero) < b) {
      return (cut: b, advancesAtCut: false);
    }
    final d = activePlayer.state.duration;
    if (d <= Duration.zero) return null;
    final trailing = Duration(
        milliseconds: _ref.read(playlistPlayerProvider).currentTrack?.item.trailingSilenceMs ?? 0);
    if (trailing < _minSilenceCut || trailing >= d) {
      return (cut: d, advancesAtCut: false);
    }
    return (cut: d - trailing, advancesAtCut: true);
  }

  void _crossfadeTick() {
    final next = _armedTrack;
    final fade = crossfadeDuration;
    if (next == null || fade == Duration.zero) return;
    final active = activePlayer;
    final pos = active.state.position;

    final session = _crossfade;
    if (session != null) {
      // 終端に達した（playing=false になる）。スワップは LoopNotifier 経由で来る
      if (active.state.completed) return;
      // 一時停止・巻き戻し（ABループでA点に戻った場合も）は取り消す
      if (!active.state.playing || pos < session.start) {
        _cancelCrossfade();
        return;
      }
      final progress = session.step(pos);
      _ref.read(crossfadeProgressProvider.notifier).state =
          (progress: progress, next: next.item);
      // 曲末の無音を飛ばす場合、切断点で自分から遷移を起こす（B点到達と同じ経路）
      if (session.advancesAtCut && !session.advanced && pos >= session.cut) {
        session.advanced = true;
        _ref.read(loopProvider.notifier).onTrackEnd?.call();
      }
      return;
    }

    if (!active.state.playing) return;
    final ls = _ref.read(loopProvider);
    if (ls.isInGap) return;
    if (_ref.read(playlistPlayerProvider).repeatMode == RepeatMode.single) {
      return;
    }
    final cutPoint = _cutPoint();
    if (cutPoint == null) return;
    final cut = cutPoint.cut;
    final start = cut - fade;
    // 区間が短いと頭から交差になるので、最低2秒は素で鳴らす
    final current = _ref.read(playlistPlayerProvider).currentTrack;
    final regionStart = ls.enabled
        ? (ls.pointA ?? Duration.zero)
        : current != null
            ? effectiveStart(current)
            : Duration.zero;
    if (start < regionStart + const Duration(seconds: 2)) return;
    if (pos < start || pos >= cut) return;
    _beginCrossfade(next, start, cut, advancesAtCut: cutPoint.advancesAtCut);
  }

  Future<void> _beginCrossfade(PlaylistTrack next, Duration start, Duration cut,
      {required bool advancesAtCut}) async {
    final inPlayer = preloadPlayer;
    final baseRate = inPlayer.state.rate;
    final session = _CrossfadeSession(
      outPlayer: activePlayer,
      inPlayer: inPlayer,
      start: start,
      cut: cut,
      advancesAtCut: advancesAtCut,
      volume: activePlayer.state.volume,
      inStart: effectiveStart(next),
      inBaseRate: baseRate,
      inRate: _tempoMatchedRate(next, baseRate) ?? baseRate,
    );
    _crossfade = session;
    try {
      if (session.inRate != baseRate) await inPlayer.setRate(session.inRate);
      await inPlayer.setVolume(0);
      await inPlayer.play();
      if (_crossfade == session) {
        _ref.read(crossfadeProgressProvider.notifier).state =
            (progress: 0, next: next.item);
      }
    } catch (e) {
      debugPrint('[PlaylistEngine] クロスフェード開始に失敗: $e');
      if (_crossfade == session) _crossfade = null;
    }
  }

  void _cancelCrossfade() {
    final session = _crossfade;
    if (session == null) return;
    _crossfade = null;
    _ref.read(crossfadeProgressProvider.notifier).state = null;
    session.rollback();
  }

  // --- テンポ合わせ ---
  //
  // 交差中は次曲の速度を前曲の「実際に鳴っているテンポ」に寄せ、前曲が消えた後に
  // 本来の速度へ数秒かけて戻す（DJ がピッチフェーダーを戻す動き）。
  // 倍/半テンポは同一視し、速度変化が大きすぎる組み合わせは何もしない。

  static const _tempoRampDuration = Duration(seconds: 4);
  static const _tempoRampStep = Duration(milliseconds: 200);

  Timer? _tempoRamp;
  Player? _tempoRampPlayer;

  /// 次曲に設定すべき速度。合わせない（設定オフ・不明・差が大きい）なら null
  double? _tempoMatchedRate(PlaylistTrack next, double inBaseRate) {
    if (!_ref.read(tempoMatchProvider)) return null;
    final outBpm = _ref.read(playlistPlayerProvider).currentTrack?.item.bpm;
    final inBpm = next.item.bpm;
    if (outBpm == null || inBpm == null) return null;
    final ratio = TrackCompatibility.tempoRatio(
        outBpm * activePlayer.state.rate, inBpm * inBaseRate);
    if (ratio == null) return null;
    if ((ratio - 1).abs() * 100 > TrackCompatibility.maxTempoAdjustPercent) {
      return null;
    }
    final rate = inBaseRate * ratio;
    return (rate - inBaseRate).abs() < 0.005 ? null : rate;
  }

  void _startTempoRamp(Player player, double from, double to) {
    _cancelTempoRamp();
    _tempoRampPlayer = player;
    final startedAt = DateTime.now();
    _tempoRamp = Timer.periodic(_tempoRampStep, (timer) {
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      final t = (elapsed / _tempoRampDuration.inMilliseconds).clamp(0.0, 1.0);
      player.setRate(from + (to - from) * t);
      if (t >= 1) _cancelTempoRamp();
    });
  }

  void _cancelTempoRamp() {
    _tempoRamp?.cancel();
    _tempoRamp = null;
    _tempoRampPlayer = null;
  }

  // --- 区間の適用 ---

  /// トラックのAB区間を loopProvider に反映する。区間なしならループ解除。
  void applyRegion(PlaylistTrack track) {
    final notifier = _ref.read(loopProvider.notifier);
    if (!track.hasRegion) {
      notifier.reset();
      return;
    }
    notifier.setPointA(
        track.startMs != null ? Duration(milliseconds: track.startMs!) : null);
    notifier.setPointB(
        track.endMs != null ? Duration(milliseconds: track.endMs!) : null);
    if (!_ref.read(loopProvider).enabled) notifier.toggleEnabled();
  }

  // --- 遷移可否の判定 ---

  /// 次トラックへ進めるかを判定する。
  ///
  /// [preloadedIndex] はプリロード済みトラックのインデックス（未プリロードなら null）。
  /// [pendingJumpIndex] は手動選択の予約（次の自動遷移でそこへ跳ぶ）。
  AdvanceReadiness readiness({
    int? preloadedIndex,
    int? pendingJumpIndex,
  }) {
    final ps = _ref.read(playlistPlayerProvider);
    final nextIdx = ps.peekNextTrackIndex();
    if (nextIdx == null && pendingJumpIndex == null) return AdvanceReadiness.none;

    final current = ps.currentTrack;
    if (nextIdx != null &&
        current != null &&
        ps.tracks[nextIdx].isSameItem(current)) {
      return AdvanceReadiness.sameItem;
    }
    if (preloadedIndex != null &&
        (pendingJumpIndex == preloadedIndex || nextIdx == preloadedIndex)) {
      return AdvanceReadiness.preloaded;
    }
    return AdvanceReadiness.notReady;
  }
}

/// クロスフェード1回分。開始時の旧プレイヤーの音量を交差後の目標にする
class _CrossfadeSession {
  _CrossfadeSession({
    required this.outPlayer,
    required this.inPlayer,
    required this.start,
    required this.cut,
    required this.advancesAtCut,
    required this.volume,
    required this.inStart,
    required this.inBaseRate,
    required this.inRate,
  });

  final Player outPlayer;
  final Player inPlayer;
  final Duration start;
  final Duration cut;

  /// 切断点が曲の終端より手前（曲末の無音を飛ばす）なので、到達時に遷移を起こす
  final bool advancesAtCut;
  bool advanced = false;

  final double volume;

  /// 取り消し時に新プレイヤーを戻す位置（次曲のA点）
  final Duration inStart;

  /// 次曲本来の速度と、交差中にテンポを寄せた速度（寄せないときは同じ値）
  final double inBaseRate;
  final double inRate;

  /// 音量を交差させ、進捗（0〜1）を返す
  double step(Duration pos) {
    final total = (cut - start).inMilliseconds;
    final t = total <= 0
        ? 1.0
        : ((pos - start).inMilliseconds / total).clamp(0.0, 1.0);
    // 等パワー曲線（中間点で合計の音圧が落ち込まない）
    final angle = t * pi / 2;
    outPlayer.setVolume(volume * cos(angle));
    inPlayer.setVolume(volume * sin(angle));
    return t;
  }

  /// 切断点で呼ぶ（旧プレイヤーは停止済み）。
  /// 旧プレイヤーを音量0のままにすると、次にプリロード側として再利用されたとき無音になる
  void finish() {
    inPlayer.setVolume(volume);
    outPlayer.setVolume(volume);
  }

  /// 取り消し。新プレイヤーを頭に戻して待機状態へ
  void rollback() {
    inPlayer.pause();
    inPlayer.seek(inStart);
    inPlayer.setVolume(volume);
    if (inRate != inBaseRate) inPlayer.setRate(inBaseRate);
    outPlayer.setVolume(volume);
  }
}
