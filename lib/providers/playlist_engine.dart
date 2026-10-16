import 'dart:math';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/audio/beat_grid.dart';
import '../core/audio/audio_quality.dart';
import '../core/audio/crossfade_curve.dart';
import '../core/audio/sfx_library.dart';
import '../core/audio/track_compatibility.dart';
import '../core/audio/transition_effect.dart';
import '../models/loop_item.dart';
import '../models/playlist_mode.dart';
import '../models/playlist_track.dart';
import '../services/audio_filters.dart';
import '../services/cache_service.dart';
import '../services/deck_tricks.dart';
import '../services/playback/hq_audio.dart';
import '../services/playback/media_cache.dart';
import '../services/transition_sfx.dart';
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
    // 低音シェルフとスイープ用ローパスを 0dB・全開で付けておく（交差中は値だけ動かす）。
    // 前回の交差の残り（2 枚のプレイヤーを使い回すため）もここで消える
    await AudioFilters.install(player);
    // ブレーキ（音程補正オフ）やループロール（mpv の AB ループ）の残りも戻す
    await DeckTricks.reset(player);

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
      out: plan.outBars,
      in_: plan.inBars,
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

    // 切替点の瞬間の効果音（インパクト）はここで鳴らす
    session?.onCut();
    if (session != null && session.outVolume > 1) {
      // 曲線が 0 に着く前にスワップが来た（YouTube の音声がメタデータの長さより
      // 早く終わった等）。即 stop すると旧曲がぶつぎりになるので短く落としてから止める
      session.finishIn();
      unawaited(_fadeOutAndStop(oldPlayer, session.outVolume, session.volume)
          .then((_) => session.clearOut()));
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

  /// プレイリスト再生のひと続きの番号。ミニプレイヤーの進行役（MiniPlayerTransport）は
  /// 作られたときの値を覚え、変わっていたら何もしない。
  /// 以前は別の曲を開いても進行役が止まらず、途中だった先読みが終わると
  /// プレイリストの次の曲を読み込んでクロスフェードを予約し、単体再生の曲末で鳴り出していた
  int get session => _session;
  int _session = 0;

  /// 今のプレイリスト再生を打ち切る（進行役の先読み・遷移を無効にする）。
  /// [keepCrossfade] は同じプレイリストの再生画面に戻るとき（予約はそのまま使える）
  void endSession({bool keepCrossfade = false}) {
    _session++;
    if (!keepCrossfade) disarmCrossfade();
  }

  /// 単体再生・AB 設定など、プレイリストでない再生を始めるとき。
  /// ミニプレイヤーで続いていたプレイリストの後始末（進行役・クロスフェード予約・
  /// ループのコールバック・プレイリストの状態）をまとめて行う
  void endPlaylist() {
    endSession();
    _ref.read(loopProvider.notifier)
      ..onBPointReached = null
      ..onTrackEnd = null;
    _ref.read(playlistPlayerProvider.notifier).clear();
  }
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

  /// クロスフェードの長さ。設定は拍数（DJ は小節で数える）なので、出る曲の
  /// 実効テンポ（BPM × 速度）で秒にする。BPM が無い曲は 120 BPM とみなす（8 拍 = 4 秒）
  Duration get crossfadeDuration {
    final beats = _ref.read(crossfadeProvider);
    if (beats <= 0) return Duration.zero;
    return Duration(milliseconds: (beats * 60000 / _referenceBpm()).round());
  }

  /// 拍を秒に直すときのテンポ。今鳴っている曲 → 予約済みの次曲 → 120
  double _referenceBpm() {
    final current = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final bpm = current?.bpm ?? _armedTrack?.item.bpm;
    if (bpm == null || bpm <= 0) return 120;
    final rate = current == null ? 1.0 : activePlayer.state.rate;
    return bpm * (rate > 0 ? rate : 1);
  }

  /// 出る曲の 1 拍（媒体のミリ秒）。格子が無ければ [_referenceBpm] から
  double _outBeatMs() {
    final grid = _ref.read(playlistPlayerProvider).currentTrack?.item.beatGrid;
    return grid != null && grid.reliable ? grid.periodMs : 60000 / _referenceBpm();
  }

  /// 次曲のプリロードが完了したら呼ぶ。切断点の手前で自動的に交差を始める。
  /// 拍合わせの分だけ開始位置をずらすシークはここで済ませておく（交差開始時の遅れを減らす）
  void armCrossfade(PlaylistTrack next) {
    _armedTrack = next;
    _crossfadeMonitor ??= Timer.periodic(
        const Duration(milliseconds: 100), (_) => _crossfadeTick());
    if (crossfadeDuration != Duration.zero) {
      unawaited(realignPreload(next));
      unawaited(_preloadSfx());
    }
  }

  // --- 効果音 ---

  /// 切り替えごとに回す（同じ長さのライザーが何種類かある）
  int _sfxVariant = 0;

  /// 今の演出で鳴らす効果音（鳴らす順）。[windowMs] はクロスフェードの実時間
  List<SfxClip> _sfxClips(TransitionEffect effect, int windowMs) {
    final lead = effect.leadInSfx;
    return [
      if (lead != null)
        SfxLibrary.pick(lead, windowMs: windowMs, variant: _sfxVariant),
      if (effect.impactAtCut)
        SfxLibrary.pick(SfxRole.impact, windowMs: windowMs, variant: _sfxVariant),
    ];
  }

  /// 出る曲の [from] 〜 [to]（媒体）が実時間で何ミリ秒か
  int _realMs(Duration from, Duration to) {
    final rate = activePlayer.state.rate;
    final ms = (to - from).inMilliseconds / (rate > 0 ? rate : 1);
    return ms <= 0 ? 0 : ms.round();
  }

  /// 効果音を使う演出なら、プレイヤーを起こして音源を開いておく（交差の開始で待たないため）。
  /// 演出は交差を始めるときにもう一度読むので、ここで開いたものと違えばそのとき開き直す
  Future<void> _preloadSfx() async {
    final effect = _ref.read(transitionEffectProvider);
    if (!effect.usesSfx) return;
    final planned = plannedCrossfade();
    final windowMs = planned == null
        ? crossfadeDuration.inMilliseconds
        : _realMs(planned.start, planned.cut);
    try {
      await _ref.read(transitionSfxProvider).load(_sfxClips(effect, windowMs));
    } catch (e) {
      debugPrint('[PlaylistEngine] 効果音の先読みに失敗: $e');
    }
  }

  /// トリック（ブレーキ・ループロール）の終わりで、切替点を待たずに遷移を起こす。
  /// 出る曲の位置が切替点に届かない（遅くなる・戻る）ので、実時間で合図する
  void _forceCut(_CrossfadeSession session) {
    if (_crossfade != session || session.advanced) return;
    session.advanced = true;
    _ref.read(loopProvider.notifier).onTrackEnd?.call();
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
        return _snapToBar(item, (cut: cut, advancesAtCut: true));
      }
    }
    final trailing = Duration(milliseconds: item?.trailingSilenceMs ?? 0);
    if (trailing < _minSilenceCut || trailing >= d) {
      return _snapToBar(
          item, (cut: d - LoopNotifier.trackEndLead, advancesAtCut: false));
    }
    return _snapToBar(item, (cut: d - trailing, advancesAtCut: true));
  }

  /// 切断点を直前の小節頭（ドロップを基準に 4 拍ごと）へ寄せる。DJ は区切りで切り替える。
  /// 格子が無い・信用できない曲はそのまま。手前に動かしたら遷移はこちらから起こす
  ({Duration cut, bool advancesAtCut}) _snapToBar(
      LoopItem? item, ({Duration cut, bool advancesAtCut}) raw) {
    final grid = item?.beatGrid;
    if (grid == null || !grid.reliable) return raw;
    final bars = grid.barGrid(item!.mixInMs?.toDouble());
    final snappedMs = bars.floorBeatMs(raw.cut.inMicroseconds / 1000);
    final snapped = Duration(microseconds: (snappedMs * 1000).round());
    if (snapped <= Duration.zero ||
        snapped >= raw.cut - const Duration(milliseconds: 1) ||
        activePlayer.state.position >= snapped) {
      return raw;
    }
    return (cut: snapped, advancesAtCut: true);
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
    final curve = _ref.read(crossfadeCurveProvider);
    // ベーススワップの位置: 曲線の決める進捗を、出る曲の次の拍の頭へ寄せる（区切りで一動作）
    final beatMs = _outBeatMs();
    final outGrid = _ref.read(playlistPlayerProvider).currentTrack?.item.beatGrid;
    final atMs = (start + (cut - start) * curve.bassSwapAt).inMicroseconds / 1000;
    final cutMs = cut.inMicroseconds / 1000;
    var swapStartMs = atMs;
    if (curve.bassSwapAt < 1 && outGrid != null && outGrid.reliable) {
      final floor = outGrid.floorBeatMs(atMs);
      final ceil = floor < atMs - 1 ? floor + outGrid.periodMs : floor;
      if (ceil < cutMs) swapStartMs = ceil;
    }
    final swapEndMs = curve.bassSwapAt < 1
        ? min(swapStartMs + beatMs * _CrossfadeSession.bassSwapBeats, cutMs)
        : cutMs;
    final outRate = activePlayer.state.rate;
    final beatRealMs = beatMs / (outRate > 0 ? outRate : 1);
    final effect = _ref.read(transitionEffectProvider);
    final volume = activePlayer.state.volume;
    final session = _CrossfadeSession(
      outPlayer: activePlayer,
      inPlayer: inPlayer,
      start: start,
      cut: cut,
      advancesAtCut: advancesAtCut,
      volume: volume,
      inStart: inStart,
      inBaseRate: baseRate,
      inRate: inRate,
      curve: curve,
      // トリック系は切替点まで前の曲だけなので、低音の入れ替えはしない
      bassSwap: !effect.cutsHard && _ref.read(bassSwapProvider),
      effect: effect,
      beat: beat,
      swapStartMs: swapStartMs,
      swapEndMs: swapEndMs,
      // エコーの遅延は半拍（実時間）
      echoDelayMs: (beatRealMs / 2).round(),
      outRate: outRate,
      beatRealMs: beatRealMs,
      beatMediaMs: beatMs,
      sfx: effect.usesSfx ? _ref.read(transitionSfxProvider) : null,
      sfxVolume: TransitionSfx.volumeFor(volume, _ref.read(sfxLevelProvider)),
      onForceCut: _forceCut,
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
      // 入る曲は低音を切った状態で重ね始める（鳴らす前に値を変えるので音切れしない）
      if (session.bassSwap) {
        await AudioFilters.setBassDb(inPlayer, AudioFilters.bassCutDb);
      }
      await inPlayer.play();
      // 効果音を開く（armCrossfade で同じものを開いてあれば一瞬で返る）
      if (session.sfx != null) {
        await session.sfx!.load(_sfxClips(effect, _realMs(start, cut)));
        _sfxVariant++;
      }
      if (_crossfade == session) {
        // 効果音・トリックは実時間で予定する（切替点までの残り時間から）
        final toCutMs = _realMs(activePlayer.state.position, cut);
        session.startTricks(wallToCutMs: toCutMs);
        if (effect != TransitionEffect.none) {
          debugPrint('[DjFx] 演出 ${effect.name} 切替点まで ${toCutMs}ms '
              '1拍 ${beatRealMs.round()}ms 効果音 ${session.sfx?.loaded ?? const []} '
              '開始遅延見込み ${TransitionSfx.startLatencyMs.round()}ms');
        }
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
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final outGrid = outItem?.beatGrid;
    final inGrid = next.item.beatGrid;
    // 格子が当てはまっていない曲（生演奏・揺れる曲）は合わせようとしない方が自然
    if (outGrid == null || inGrid == null || !outGrid.reliable || !inGrid.reliable) {
      return null;
    }
    final outRate = activePlayer.state.rate;
    if (outRate <= 0 || inRate <= 0) return null;
    final ratio = TrackCompatibility.tempoRatio(
        outGrid.bpm * outRate, inGrid.bpm * inRate);
    return _BeatPlan(
      outGrid: outGrid,
      inGrid: inGrid,
      // 重ね始めは小節（ドロップを小節頭とみなして 4 拍ごと）で揃える。
      // 切断点も小節頭なので、入る曲のドロップが切り替わりの瞬間に来る
      outBars: outGrid.barGrid(outItem!.mixInMs?.toDouble()),
      inBars: inGrid.barGrid(next.item.mixInMs?.toDouble()),
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
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final outBpm = outItem?.bpm;
    final inBpm = next.item.bpm;
    if (outBpm == null || inBpm == null) return null;
    // 格子が当てはまっていない曲はテンポも揺れている。寄せても合わないので触らない
    if (outItem?.beatGrid?.reliable == false || next.item.beatGrid?.reliable == false) {
      return null;
    }
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
    required this.outBars,
    required this.inBars,
    required this.outRate,
    required this.inRate,
    required this.lock,
  });

  final BeatGrid outGrid;
  final BeatGrid inGrid;

  /// 小節の格子（重ね始めの位置合わせ用。交差中のナッジは拍の格子で）
  final BeatGrid outBars;
  final BeatGrid inBars;
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
    required this.swapStartMs,
    required this.swapEndMs,
    required this.echoDelayMs,
    required this.outRate,
    required this.beatRealMs,
    required this.beatMediaMs,
    required this.sfx,
    required this.sfxVolume,
    required this.onForceCut,
  })  : outVolume = volume,
        appliedInRate = inRate;

  /// ベーススワップにかける拍数（DJ の「一動作」。ゆっくり交差させない）
  static const bassSwapBeats = 2;

  /// 交差開始時の出る曲の速度。ブレーキで落とした後はこれに戻す
  final double outRate;

  /// 出る曲の 1 拍（実時間 / 媒体のミリ秒）
  final double beatRealMs;
  final double beatMediaMs;

  /// 効果音（使わない演出なら null）と、その音量（0〜100 の尺度）
  final TransitionSfx? sfx;
  final double sfxVolume;

  /// トリックの終わりに切替点を待たずに遷移を起こす
  final void Function(_CrossfadeSession) onForceCut;

  // --- トリック（実時間のタイマーで進める） ---

  /// ブレーキの長さ（拍）と、実時間での下限・上限
  static const brakeBeats = 2;
  static const brakeMinMs = 700;
  static const brakeMaxMs = 2500;

  /// ブレーキの終わりの速度（mpv の下限 0.01 より上。ほぼ止まった低い唸り）
  static const brakeMinRate = 0.05;

  /// ループロールは最後の 1 小節。(始まる拍, ループの長さ(拍))
  static const loopRollBeats = 4;
  static const loopRollStages = [(0.0, 1.0), (2.0, 0.5), (3.0, 0.25), (3.5, 0.125)];

  final _timers = <Timer>[];
  Timer? _brakeTimer;
  bool _tricksStarted = false;

  /// トリック中の出る曲の音量比（null = 曲線のまま）
  double? _outOverride;

  /// 効果音とトリックを予定する。[wallToCutMs] は切替点までの実時間
  void startTricks({required int wallToCutMs}) {
    if (_tricksStarted) return;
    _tricksStarted = true;
    final toCut = max(0, wallToCutMs);
    final lead = effect.leadInSfx;
    final s = sfx;
    if (lead != null && s != null) {
      final clip = s.loaded.firstOrNull;
      if (clip != null) {
        // 終わりが切替点に来るように。開始の遅れの分だけ前倒す
        _after(toCut - clip.durationMs - TransitionSfx.startLatencyMs.round(), () {
          unawaited(s.start(volume: sfxVolume));
          // スピンバックはレコードを巻き取る音なので、曲はすぐ消す
          if (effect == TransitionEffect.spinback) _killOut();
        });
      }
    }
    switch (effect) {
      case TransitionEffect.brake:
        final durMs =
            (beatRealMs * brakeBeats).round().clamp(brakeMinMs, brakeMaxMs);
        _after(toCut - durMs, () => _startBrake(durMs));
      case TransitionEffect.loopRoll:
        _after(toCut - (beatRealMs * loopRollBeats).round(), _startLoopRoll);
      default:
        break;
    }
  }

  void _after(int ms, void Function() fn) {
    _timers.add(Timer(Duration(milliseconds: max(0, ms)), fn));
  }

  void _setOut(double level) {
    _outOverride = level.clamp(0.0, 1.0);
    outVolume = volume * _outOverride!;
    outPlayer.setVolume(outVolume);
  }

  /// 出る曲を 200ms で消す
  void _killOut() {
    for (var i = 1; i <= 4; i++) {
      _after(i * 50, () => _setOut(1 - i / 4));
    }
  }

  /// ブレーキ: 速度をほぼ一定の減速で落とす（レコードが止まる動き）。音程も一緒に落ちる。
  /// 音量は最後の 3 割で落とし、止まったら切替点を待たずに次の曲へ
  void _startBrake(int durMs) {
    unawaited(DeckTricks.setPitchCorrection(outPlayer, false));
    final t0 = DateTime.now();
    _brakeTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      final x = DateTime.now().difference(t0).inMilliseconds / durMs;
      if (x >= 1) {
        timer.cancel();
        _setOut(0);
        onForceCut(this);
        return;
      }
      unawaited(outPlayer.setRate(outRate * max(brakeMinRate, 1 - x)));
      if (x > 0.7) _setOut((1 - x) / 0.3);
    });
  }

  /// ループロール: 切替点の 1 小節前から、同じ始点で 1 → 1/2 → 1/4 → 1/8 拍のループを
  /// 刻む（mpv の AB ループ）。小節が終わったら切替点を待たずに次の曲へ
  void _startLoopRoll() {
    final cutMs = cut.inMicroseconds / 1000;
    final aMs = max(start.inMicroseconds / 1000, cutMs - beatMediaMs * loopRollBeats);
    for (final (atBeat, lenBeats) in loopRollStages) {
      _after((atBeat * beatRealMs).round(), () {
        unawaited(DeckTricks.setAbLoop(outPlayer, aMs, aMs + lenBeats * beatMediaMs));
      });
    }
    _after((loopRollBeats * beatRealMs).round(), () {
      _setOut(0);
      unawaited(DeckTricks.clearAbLoop(outPlayer));
      onForceCut(this);
    });
  }

  void _cancelTricks() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _brakeTimer?.cancel();
    _brakeTimer = null;
  }

  /// 切替点（スワップ）で呼ぶ。まだ待っていた効果音・トリックは捨て、
  /// 切替点の瞬間の効果音（インパクト単独）を鳴らす。ライザーの後のインパクトは
  /// プレイリストで続けて鳴る
  void onCut() {
    _cancelTricks();
    if (effect.impactAtCut && effect.leadInSfx == null) {
      unawaited(sfx?.start(volume: sfxVolume));
    }
  }

  /// ベーススワップの開始・終了位置（出る曲の媒体ミリ秒）。開始は拍の頭に寄せてある。
  /// 演出（スイープ・エコー）も開始位置から切替点にかけて
  final double swapStartMs;
  final double swapEndMs;

  /// エコーアウトの遅延（実時間ミリ秒、半拍）
  final int echoDelayMs;

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
    // トリック中は出る曲の位置が遅くなる・戻るので、位相を測っても意味がない
    if (plan == null || !plan.lock || effect.cutsHard) return;
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

  /// スワップの開始位置を通過したか（エコーを付けるのは一度だけ）
  bool _swapped = false;

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
    // トリック系は切替点まで前の曲だけ（カットと同じ）。トリックが音量を握っていればそれに従う
    final levels = effect.cutsHard ? CrossfadeCurve.cut.levels(t) : curve.levels(t);
    outVolume = volume * (_outOverride ?? levels.out);
    outPlayer.setVolume(outVolume);
    inPlayer.setVolume(volume * levels.in_);

    final posMs = pos.inMicroseconds / 1000;
    final cutMs = cut.inMicroseconds / 1000;
    if (posMs >= swapStartMs && t < 1) {
      // ベーススワップ: 拍の頭から 2 拍かけて、出る曲の低音を切りつつ入る曲の低音を戻す
      // （フィルタは付けっぱなしで値だけ動かすので音は途切れない）
      if (bassSwap && swapEndMs > swapStartMs) {
        final r = ((posMs - swapStartMs) / (swapEndMs - swapStartMs)).clamp(0.0, 1.0);
        unawaited(AudioFilters.setBassDb(outPlayer, AudioFilters.bassDb(r)));
        unawaited(AudioFilters.setBassDb(inPlayer, AudioFilters.bassDb(1 - r)));
      }
      // エコーアウト: 出る曲に半拍のエコーを付ける（グラフの作り直しはこの 1 回だけ）
      if (!_swapped) {
        _swapped = true;
        if (effect.echoesOut) {
          unawaited(AudioFilters.setEcho(outPlayer, echoDelayMs));
        }
      }
      // スイープ: スワップの位置から切替点にかけてローパスを閉じていく
      if (effect.sweepsOut && cutMs > swapStartMs) {
        unawaited(AudioFilters.setSweep(outPlayer,
            AudioFilters.sweepHz((posMs - swapStartMs) / (cutMs - swapStartMs))));
      }
    }
    return t;
  }

  /// 切断点で呼ぶ（旧プレイヤーは停止済み）。
  /// 旧プレイヤーを音量0のままにすると、次にプリロード側として再利用されたとき無音になる
  void finish() {
    finishIn();
    outPlayer.setVolume(volume);
    clearOut();
  }

  /// 新プレイヤーだけ本来の音量に戻す（旧プレイヤーは別途落としてから戻す）。
  /// 低音が戻り切っていなければ戻す（ランプの途中でスワップが来た場合）
  void finishIn() {
    inPlayer.setVolume(volume);
    if (bassSwap) unawaited(AudioFilters.reset(inPlayer));
  }

  /// 出る曲のフィルタとトリックを初期状態に戻す（停止した後に呼ぶ。次にプリロード側として使うため）
  void clearOut() {
    _cancelTricks();
    unawaited(AudioFilters.reset(outPlayer));
    unawaited(DeckTricks.reset(outPlayer));
    if (effect == TransitionEffect.brake) unawaited(outPlayer.setRate(outRate));
  }

  /// 取り消し。新プレイヤーを頭に戻して待機状態へ。効果音も止める
  void rollback() {
    _cancelTricks();
    unawaited(sfx?.stop());
    inPlayer.pause();
    inPlayer.seek(inStart);
    inPlayer.setVolume(volume);
    if (appliedInRate != inBaseRate) inPlayer.setRate(inBaseRate);
    outPlayer.setVolume(volume);
    if (bassSwap) unawaited(AudioFilters.reset(inPlayer));
    clearOut();
  }
}
