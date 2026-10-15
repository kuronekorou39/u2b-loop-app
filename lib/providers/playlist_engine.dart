import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/audio/beat_grid.dart';
import '../core/audio/audio_quality.dart';
import '../core/audio/crossfade_curve.dart';
import '../core/audio/track_compatibility.dart';
import '../core/audio/transition_effect.dart';
import '../models/loop_item.dart';
import '../models/playlist_mode.dart';
import '../models/playlist_track.dart';
import '../services/audio_filters.dart';
import '../services/cache_service.dart';
import '../services/playback/hq_audio.dart';
import '../services/playback/media_cache.dart';
import '../services/youtube_service.dart';
import 'loop_provider.dart';
import 'player_provider.dart';
import 'playlist_player_provider.dart';

final playlistEngineProvider =
    Provider<PlaylistEngine>((ref) => PlaylistEngine(ref));

/// クロスフェードの進捗（0〜1）と、鳴り始めている次曲
typedef CrossfadeProgress = ({double progress, LoopItem next});

/// 交差していないときは null。
/// 画面の遷移演出（動画が引いて次曲サムネが出る）がこれを見て描く
final crossfadeProgressProvider =
    StateProvider<CrossfadeProgress?>((ref) => null);

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

  // --- プリロード / ロードの共通機構 ---

  /// [player] に [track] を読み込んで再生準備を整える。
  ///
  /// - オフライン保存済みならローカルファイルを使う（通信なし・即時）
  /// - duration が取れない場合は無音で短く再生してメタデータを確定させる
  ///   （duration=0 のままだとループ監視も終端検知も働かない）
  /// - 開始位置へシークし、**毎回**速度を設定する
  ///   （プレイヤーを2枚使い回す設計のため、設定しないと前曲の速度が残る）
  ///
  /// 高音質の音声（HqAudio）を待つ上限。プリロードは次の曲までに間に合えばよい
  static const hqAudioWait = Duration(seconds: 30);

  /// [prepare] の downloadFirst で映像を落とし切るのを待つ上限。超えたらストリーミングで開く
  static const videoDownloadWait = Duration(seconds: 30);

  /// [isStale] が true を返した時点で処理を打ち切る（曲を素早く切り替えた際のレース対策）。
  /// 戻り値は YouTube のマニフェスト（波形の先行生成に再利用するため）。
  /// キャッシュ再生・ローカルファイルの場合は null。
  ///
  /// YouTube は自動キャッシュ（[MediaCache]）に映像が残っていれば通信なしで開く。
  /// 無ければ、[downloadFirst]（プリロード。時間に余裕がある）なら落としてから開き、
  /// そうでなければストリーミングで開いて、少し後に裏で落とす
  Future<StreamManifest?> prepare(
    Player player,
    PlaylistTrack track, {
    bool Function()? isStale,
    bool waitForMetadata = true,
    bool downloadFirst = false,
  }) async {
    bool stale() => isStale?.call() ?? false;
    final item = track.item;

    // どちらのプレイヤーを読み直す場合も、進行中のクロスフェードは成立しなくなる
    disarmCrossfade();
    // 読み直す側がテンポを戻している途中なら、その速度を上書きされないよう止める
    if (identical(player, _tempoRampPlayer)) _cancelTempoRamp();
    // 前回の交差のフィルタ（低音カット・演出）が残っていたら外す（2 枚のプレイヤーを使い回すため）
    await AudioFilters.clear(player);

    StreamManifest? manifest;
    // 高音質の音声（音声専用ストリーム）。開くのと並行して落とし、メタデータ確定後に付ける
    Future<String?>? hqAudio;
    final quality = _ref.read(audioQualityProvider.notifier);
    final cached = CacheService.offlineVideoPath(item);
    if (cached != null) {
      quality.set(player, AudioQuality.offline);
      await player.open(Media(cached), play: false);
    } else if (item.isYouTube && item.videoId != null) {
      final videoId = item.videoId!;
      var local = await MediaCache.existingVideo(videoId);
      if (local == null) {
        final ytService = _ref.read(youtubeServiceProvider);
        manifest = await ytService.getManifestWithFallback(videoId);
        if (stale()) return null;
      }
      if (HqAudio.enabled) {
        HqAudio.log('エンジン: 取得を依頼');
        hqAudio = HqAudio.fetch(videoId, manifest: manifest, isCancelled: stale);
      }
      if (local == null) {
        if (downloadFirst) {
          local = await MediaCache.fetchVideo(videoId, manifest!, isCancelled: stale)
              .timeout(videoDownloadWait, onTimeout: () => null);
          if (stale()) return manifest;
        } else {
          MediaCache.cacheVideoLater(videoId, manifest!, isCancelled: stale);
        }
      }
      quality.set(player, AudioQuality.standard);
      await player.open(
          Media(local ?? YouTubeService.pickStreamUrl(manifest!)),
          play: false);
    } else {
      quality.set(player, AudioQuality.local);
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

    if (hqAudio != null) {
      // プリロードは次の曲までに間に合えばよいので、落ち切るまで待つ（打ち切りは stale）。
      // それでも間に合わなければ、落ち次第まだ同じ曲ならその場で付け替える
      Future<void> attach(String path) async {
        if (await HqAudio.attach(player, path)) {
          quality.set(player, AudioQuality.hq(HqAudio.labelFor(path)));
        }
      }

      var timedOut = false;
      final path = await hqAudio.timeout(hqAudioWait, onTimeout: () {
        timedOut = true;
        return null;
      });
      if (stale()) {
        HqAudio.log('エンジン: 曲が変わったので付けない');
        return manifest;
      }
      if (timedOut) {
        HqAudio.log('エンジン: ${hqAudioWait.inSeconds} 秒に間に合わず、落ち次第付ける');
        final opened = player.state.playlist.medias.firstOrNull?.uri;
        unawaited(hqAudio.then((late) {
          if (late == null) return null;
          if (stale() || player.state.playlist.medias.firstOrNull?.uri != opened) {
            HqAudio.log('エンジン: 落ちたが曲が変わっていたので付けない');
            return null;
          }
          return attach(late);
        }));
      } else if (path != null) {
        HqAudio.log('エンジン: 取り付けへ');
        await attach(path);
      } else {
        HqAudio.log('エンジン: 落とせなかったので一体型のまま');
      }
    }

    await player.seek(effectiveStart(track));
    await player.setRate(item.speed);
    return manifest;
  }

  /// トラックの再生開始位置。区間があればA点。
  /// 無ければ、クロスフェード有効時は曲頭の無音を飛ばす（無音同士を重ねない）。
  /// さらに「ドロップに合わせる」がオンでミックスイン点が分かっていれば、
  /// 交差が終わる瞬間（切替点）にドロップが来るよう、その fade 秒前から始める
  Duration effectiveStart(PlaylistTrack track) {
    final startMs = track.startMs;
    if (startMs != null) return Duration(milliseconds: startMs);
    final fade = crossfadeDuration;
    if (fade == Duration.zero) return Duration.zero;
    final leading = Duration(milliseconds: track.item.leadingSilenceMs ?? 0);
    final mixIn = track.item.mixInMs;
    if (mixIn != null && _ref.read(mixPointAlignProvider)) {
      final aligned = Duration(milliseconds: mixIn) - fade;
      if (aligned > leading) return aligned;
    }
    return leading;
  }

  /// 交差で入る曲の実際の開始位置: [effectiveStart] に拍合わせのずらし（±半拍）を足したもの。
  /// [outStart] は出る曲の交差開始位置（省略時は予定の切断点から求める）、
  /// [inRate] は交差中の入る曲の速度。拍合わせができないときは effectiveStart のまま
  Duration plannedInStart(PlaylistTrack next,
      {Duration? outStart, required double inRate}) {
    final base = effectiveStart(next);
    final plan = _beatPlan(next, inRate);
    if (plan == null) return base;
    final start = outStart ?? _plannedStart();
    if (start == null) return base;
    final aligned = BeatMatcher.alignedStartMs(
      out: plan.outGrid,
      in_: plan.inGrid,
      outPosMs: start.inMicroseconds / 1000,
      outRate: plan.outRate,
      inStartMs: base.inMicroseconds / 1000,
      inRate: plan.inRate,
    );
    final result = Duration(microseconds: (aligned * 1000).round());
    return result < Duration.zero ? base : result;
  }

  /// 予定の交差開始位置（切断点 − フェード秒）。切断点が決まらなければ null
  Duration? _plannedStart() {
    final cutPoint = _cutPoint();
    return cutPoint == null ? null : cutPoint.cut - crossfadeDuration;
  }

  /// プリロード側の次曲の交差中の速度（テンポ合わせ後）
  double _preloadInRate(PlaylistTrack next) {
    final base = preloadPlayer.state.rate;
    return _tempoMatchedRate(next, base) ?? base;
  }

  /// この差より小さければシークし直さない
  static const _seekSlack = Duration(milliseconds: 15);

  /// プリロード済みの次曲の開始位置を今の設定・ミックス点・拍合わせで取り直す。
  /// 波形が後から届いてミックス点が決まったとき、プリロード完了時（armCrossfade）に呼ぶ
  /// （交差が始まっていれば何もしない）
  Future<void> realignPreload(PlaylistTrack track) async {
    final armed = _armedTrack;
    if (armed == null || armed.item.id != track.item.id || _crossfade != null) {
      return;
    }
    try {
      final target = plannedInStart(track, inRate: _preloadInRate(track));
      if ((preloadPlayer.state.position - target).abs() < _seekSlack) return;
      await preloadPlayer.seek(target);
    } catch (e) {
      debugPrint('[PlaylistEngine] 次曲の開始位置の取り直しに失敗: $e');
    }
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

    if (session != null && session.outVolume > 1) {
      // 曲線が 0 に着く前にスワップが来た（YouTube の音声がメタデータの長さより
      // 早く終わった等）。即 stop すると旧曲がぶつぎりになるので短く落としてから止める
      session.finishIn();
      unawaited(_fadeOutAndStop(oldPlayer, session.outVolume, session.volume)
          .then((_) => session.clearOutFilter()));
    } else {
      oldPlayer.stop();
      session?.finish();
    }
    newPlayer.play();
    // テンポを寄せていた（拍合わせのナッジ込み）なら、前曲が消えた後にゆっくり本来の速度へ戻す
    if (session != null && session.appliedInRate != session.inBaseRate) {
      _startTempoRamp(
          session.inPlayer, session.appliedInRate, session.inBaseRate);
    }
    return newPlayer;
  }

  /// 旧プレイヤーを [from] から 150ms で 0 に落として停止し、
  /// 次にプリロード側として使われたとき無音にならないよう音量を [restore] に戻す
  Future<void> _fadeOutAndStop(Player player, double from, double restore) async {
    const steps = 3;
    try {
      for (var i = 1; i <= steps; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        await player.setVolume(from * (1 - i / steps));
      }
      await player.stop();
      await player.setVolume(restore);
    } catch (e) {
      debugPrint('[PlaylistEngine] 旧プレイヤーの停止に失敗: $e');
    }
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

  /// 予定または進行中のクロスフェード区間（旧曲の時計で start〜cut）と次曲。
  /// 次曲がプリロード済みでクロスフェードが有効なときだけ返す（ミックスビュー用）
  ({Duration start, Duration cut, PlaylistTrack next})? plannedCrossfade() {
    final next = _armedTrack;
    final fade = crossfadeDuration;
    if (next == null || fade == Duration.zero) return null;
    final session = _crossfade;
    if (session != null) {
      return (start: session.start, cut: session.cut, next: next);
    }
    final cutPoint = _cutPoint();
    if (cutPoint == null) return null;
    return (start: cutPoint.cut - fade, cut: cutPoint.cut, next: next);
  }

  Duration get crossfadeDuration =>
      Duration(seconds: _ref.read(crossfadeProvider));

  /// 次曲のプリロードが完了したら呼ぶ。切断点の手前で自動的に交差を始める。
  /// 拍合わせの分だけ開始位置をずらすシークはここで済ませておく（交差開始時の遅れを減らす）
  void armCrossfade(PlaylistTrack next) {
    _armedTrack = next;
    _crossfadeMonitor ??= Timer.periodic(
        const Duration(milliseconds: 100), (_) => _crossfadeTick());
    if (crossfadeDuration != Duration.zero) unawaited(realignPreload(next));
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

  /// 切断点（スワップが実際に起きる位置）。ABループ有効ならB点。
  /// なければ「ドロップに合わせる」がオンならアウトロの落ち込み（ミックスアウト点）、
  /// 無ければ曲末の無音を除いた位置、不明なら曲の終端の [LoopNotifier.trackEndLead] 手前
  /// （LoopNotifier がそこで曲終了を発火するため。終端に合わせて曲線を引くと、
  ///   旧曲が 10〜40% の音量で止まって「ぶつぎり」に聞こえる）。
  /// [advancesAtCut] は、終端より手前で切るため遷移をこちらから起こす必要があるか
  ({Duration cut, bool advancesAtCut})? _cutPoint() {
    final ls = _ref.read(loopProvider);
    final b = ls.pointB;
    if (ls.enabled && b != null && (ls.pointA ?? Duration.zero) < b) {
      return (cut: b, advancesAtCut: false);
    }
    final d = activePlayer.state.duration;
    if (d <= Duration.zero) return null;
    final item = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final mixOut = item?.mixOutMs;
    if (mixOut != null && _ref.read(mixPointAlignProvider)) {
      final cut = Duration(milliseconds: mixOut);
      // すでに通り過ぎていたら曲末で切る
      if (cut < d - _minSilenceCut && activePlayer.state.position < cut) {
        return (cut: cut, advancesAtCut: true);
      }
    }
    final trailing = Duration(milliseconds: item?.trailingSilenceMs ?? 0);
    if (trailing < _minSilenceCut || trailing >= d) {
      return (cut: d - LoopNotifier.trackEndLead, advancesAtCut: false);
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
      session.nudgeBeats(pos);
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
    final inRate = _tempoMatchedRate(next, baseRate) ?? baseRate;
    final beat = _beatPlan(next, inRate);
    final inStart = plannedInStart(next, outStart: start, inRate: inRate);
    final session = _CrossfadeSession(
      outPlayer: activePlayer,
      inPlayer: inPlayer,
      start: start,
      cut: cut,
      advancesAtCut: advancesAtCut,
      volume: activePlayer.state.volume,
      inStart: inStart,
      inBaseRate: baseRate,
      inRate: inRate,
      curve: _ref.read(crossfadeCurveProvider),
      bassSwap: _ref.read(bassSwapProvider),
      effect: _ref.read(transitionEffectProvider),
      beat: beat,
    );
    _crossfade = session;
    try {
      if (beat != null) {
        debugPrint('[BeatMatch] 入る曲の開始 ${effectiveStart(next)} → $inStart '
            '(出 ${beat.outGrid} ×${beat.outRate} / 入 ${beat.inGrid} ×$inRate, '
            '合わせ続ける=${beat.lock})');
        // ふつうは armCrossfade で置き直してあるので、ずれていたときだけ
        if ((inPlayer.state.position - inStart).abs() >= _seekSlack) {
          await inPlayer.seek(inStart);
        }
      }
      if (session.inRate != baseRate) await inPlayer.setRate(session.inRate);
      await inPlayer.setVolume(0);
      // 入る曲は低音を切った状態で重ね始める（鳴らす前に付けるので音切れしない）
      if (session.bassSwap) await AudioFilters.apply(inPlayer, bassCut: true);
      // スイープは開いた状態のローパスを先に付けておき、後はカットオフだけ動かす
      if (session.effect == TransitionEffect.filterSweep) {
        await AudioFilters.apply(activePlayer, sweep: true);
      }
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

  // --- 拍合わせ ---

  /// 拍合わせの計画。設定オンで両方の曲に拍の格子があるときだけ。
  /// 実効テンポ（倍/半を同一視）が 0.5% 以内で揃っていれば交差中も合わせ続ける（lock）。
  /// 揃っていなければ重ね始めの拍だけ揃える（ずれていくのは仕方ない）
  _BeatPlan? _beatPlan(PlaylistTrack next, double inRate) {
    if (!_ref.read(beatMatchProvider)) return null;
    final outGrid = _ref.read(playlistPlayerProvider).currentTrack?.item.beatGrid;
    final inGrid = next.item.beatGrid;
    if (outGrid == null || inGrid == null) return null;
    final outRate = activePlayer.state.rate;
    if (outRate <= 0 || inRate <= 0) return null;
    final ratio = TrackCompatibility.tempoRatio(
        outGrid.bpm * outRate, inGrid.bpm * inRate);
    return _BeatPlan(
      outGrid: outGrid,
      inGrid: inGrid,
      outRate: outRate,
      inRate: inRate,
      lock: ratio != null && (ratio - 1).abs() < 0.005,
    );
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

/// 拍合わせ 1 回分の材料
class _BeatPlan {
  const _BeatPlan({
    required this.outGrid,
    required this.inGrid,
    required this.outRate,
    required this.inRate,
    required this.lock,
  });

  final BeatGrid outGrid;
  final BeatGrid inGrid;
  final double outRate;
  final double inRate;

  /// 交差中も位相を測って速度で合わせ続けるか（実効テンポが揃っているときだけ）
  final bool lock;
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
    required this.curve,
    required this.bassSwap,
    required this.effect,
    required this.beat,
  })  : outVolume = volume,
        appliedInRate = inRate;

  /// 拍合わせの計画（しないときは null）
  final _BeatPlan? beat;

  /// 直近に入る曲へ設定した速度（テンポ合わせ + ナッジ）。交差後はここから本来の速度へ戻す
  double appliedInRate;

  double _errSmooth = 0;
  int _nudgeTicks = 0;
  bool _measuring = false;

  /// 交差中の拍合わせ: 両プレイヤーの位置から位相のずれを測り、入る曲の速度で寄せる。
  /// play() 直後は位置が動き出すまで待つ（開始遅延はこの測定で吸収される）
  void nudgeBeats(Duration outPos) {
    final plan = beat;
    if (plan == null || !plan.lock) return;
    final inPos = inPlayer.state.position;
    if (!_measuring) {
      if (inPos <= inStart) return;
      _measuring = true;
    }
    final err = BeatMatcher.phaseErrorMs(
      out: plan.outGrid,
      in_: plan.inGrid,
      outPosMs: outPos.inMicroseconds / 1000,
      outRate: plan.outRate,
      inPosMs: inPos.inMicroseconds / 1000,
      inRate: appliedInRate,
    );
    // 位置の報告は粗いので半分ずつ平滑化してから使う
    _errSmooth = _nudgeTicks == 0 ? err : 0.5 * _errSmooth + 0.5 * err;
    _nudgeTicks++;
    final target = inRate * (1 + BeatMatcher.rateAdjust(_errSmooth));
    if ((target - appliedInRate).abs() >= 0.0005) {
      appliedInRate = target;
      unawaited(inPlayer.setRate(target));
    }
    if (_nudgeTicks % 10 == 1) {
      debugPrint('[BeatMatch] 位相誤差 ${err.toStringAsFixed(0)}ms '
          '(平滑 ${_errSmooth.toStringAsFixed(0)}ms) → rate ${target.toStringAsFixed(4)}');
    }
  }

  /// つなぎ方（音量曲線）。開始時の設定を交差の間は使い続ける
  final CrossfadeCurve curve;

  /// ベーススワップをするか。開始時に入る曲の低音を切り、[CrossfadeCurve.bassSwapAt] で
  /// 出る曲の低音を切って入る曲の低音を戻す
  final bool bassSwap;

  /// 出る曲にかける演出。ベーススワップと同じ位置から切替点までかける
  final TransitionEffect effect;

  /// [CrossfadeCurve.bassSwapAt] を通過したか（低音の入れ替えとエコーの開始は一度だけ）
  bool _swapped = false;

  /// 出る曲に何かフィルタが付いているか（停止後に外す必要がある）
  bool get _outFiltered =>
      (bassSwap && _swapped) || effect != TransitionEffect.none;

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

  /// 直近に旧プレイヤーへ設定した音量（スワップ時に残っていれば短く落とす）
  double outVolume;

  /// 音量を交差させ、進捗（0〜1）を返す
  double step(Duration pos) {
    final total = (cut - start).inMilliseconds;
    final t = total <= 0
        ? 1.0
        : ((pos - start).inMilliseconds / total).clamp(0.0, 1.0);
    final levels = curve.levels(t);
    outVolume = volume * levels.out;
    outPlayer.setVolume(outVolume);
    inPlayer.setVolume(volume * levels.in_);
    final at = curve.bassSwapAt;
    if (t >= at && t < 1) {
      // ベーススワップの位置（一度だけ）: 出る曲の低音を切り、入る曲の低音を戻す。
      // エコーアウトもここで出る曲に付ける（グラフの作り直しはこの 1 回だけ）
      if (!_swapped) {
        _swapped = true;
        final echo = effect == TransitionEffect.echoOut;
        if (bassSwap || echo) {
          unawaited(AudioFilters.apply(outPlayer,
              bassCut: bassSwap,
              sweep: effect == TransitionEffect.filterSweep,
              echo: echo));
        }
        if (bassSwap) unawaited(AudioFilters.clear(inPlayer));
      }
      // スイープ: 位置から切替点にかけてローパスを閉じていく
      if (effect == TransitionEffect.filterSweep && at < 1) {
        unawaited(AudioFilters.setSweep(
            outPlayer, AudioFilters.sweepHz((t - at) / (1 - at))));
      }
    }
    return t;
  }

  /// 切断点で呼ぶ（旧プレイヤーは停止済み）。
  /// 旧プレイヤーを音量0のままにすると、次にプリロード側として再利用されたとき無音になる
  void finish() {
    finishIn();
    outPlayer.setVolume(volume);
    clearOutFilter();
  }

  /// 新プレイヤーだけ本来の音量に戻す（旧プレイヤーは別途落としてから戻す）。
  /// 低音カットが残っていれば外す（入れ替え前にスワップが来た場合）
  void finishIn() {
    inPlayer.setVolume(volume);
    if (bassSwap && !_swapped) unawaited(AudioFilters.clear(inPlayer));
  }

  /// 出る曲のフィルタを外す（停止した後に呼ぶ。次にプリロード側として使うため）
  void clearOutFilter() {
    if (_outFiltered) unawaited(AudioFilters.clear(outPlayer));
  }

  /// 取り消し。新プレイヤーを頭に戻して待機状態へ
  void rollback() {
    inPlayer.pause();
    inPlayer.seek(inStart);
    inPlayer.setVolume(volume);
    if (appliedInRate != inBaseRate) inPlayer.setRate(inBaseRate);
    outPlayer.setVolume(volume);
    if (bassSwap) unawaited(AudioFilters.clear(inPlayer));
    clearOutFilter();
  }
}
