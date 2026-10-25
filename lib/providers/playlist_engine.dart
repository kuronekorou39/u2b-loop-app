import 'dart:math';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/audio/beat_grid.dart';
import '../core/audio/audio_quality.dart';
import '../core/audio/crossfade_curve.dart';
import '../core/audio/energy_profile.dart';
import '../core/audio/entry_planner.dart';
import '../core/audio/loudness.dart';
import '../core/audio/sfx_plan.dart';
import '../core/audio/track_compatibility.dart';
import '../core/audio/transition_effect.dart';
import '../core/audio/transition_planner.dart';
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
import 'data_provider.dart';

final playlistEngineProvider =
    Provider<PlaylistEngine>((ref) => PlaylistEngine(ref));

/// クロスフェードの進捗（0〜1）と、鳴り始めている次曲
typedef CrossfadeProgress = ({double progress, LoopItem next});

/// 交差していないときは null。
/// 画面の遷移演出（動画が引いて次曲サムネが出る）がこれを見て描く
final crossfadeProgressProvider =
    StateProvider<CrossfadeProgress?>((ref) => null);

/// 交差中に測った、2 曲の拍の頭のずれ（実時間 ms、平滑後）。正なら入る曲が遅れている。
/// 拍合わせをしていない・測れていないときは null。重ね表示に数字で出す
final beatPhaseErrorProvider = StateProvider<double?>((ref) => null);

/// ジョグホイールで手で合わせている入る曲の位置ずらし（入る曲の媒体ミリ秒、+ で曲を先へ）。
/// どの組かも持つ（組が変わったら 0 に戻す）。重ね表示の入る曲の拍の線をその場で動かし、
/// [PlaylistEngine.jog] で音にも効かせる。保存すると拍の格子に焼き込んで 0 に戻す
typedef JogOffset = ({String key, double ms});
final jogOffsetProvider = StateProvider<JogOffset?>((ref) => null);

/// ピッチフェーダーで手で直している次曲のテンポ（自動のテンポ合わせの速度に掛ける ±%）。
/// どの組かも持つ（組が変わったら 0 に戻す）。交差中は鳴っている入る曲の速度がその場で変わる。
/// 保存すると曲の BPM に焼き込んで 0 に戻す
typedef TempoTrim = ({String key, double percent});
final tempoTrimProvider = StateProvider<TempoTrim?>((ref) => null);

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
    // パークしていた前曲のプレイヤーを別の曲で開き直すなら、もう戻れない
    if (identical(player, _parkedPlayer)) _clearParked();
    // 読み直す側がテンポを戻している途中なら、その速度を上書きされないよう止める
    if (identical(player, _tempoRampPlayer)) _cancelTempoRamp();
    // 音声フィルタは外して開く（作れない列が付いたまま開くと、その曲の音声が無効になる）。
    // 前回の交差の残り（2 枚のプレイヤーを使い回すため）もここで消え、末尾で付け直す
    await AudioFilters.detach(player);
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
    // 音声が鳴れる状態になってから、低音 0dB・スイープ全開のフィルタ列を付ける
    // （交差中は値だけ動かすので音は途切れない）
    await AudioFilters.install(player);
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
    // 前曲の出口に合わせた入り口（静かなイントロを飛ばして、鳴っている段落の頭を切替点に）
    final entry = _smartEntryMs(track);
    if (entry != null) {
      final aligned = Duration(microseconds: (entry * 1000).round()) - fade;
      if (aligned > leading) return aligned;
    }
    final mixIn = track.item.mixInMs;
    if (mixIn != null && _ref.read(mixPointAlignProvider)) {
      final aligned = Duration(milliseconds: mixIn) - fade;
      if (aligned > leading) return aligned;
    }
    return leading;
  }

  /// 次曲 [next] の入り口（媒体ミリ秒）を、前曲（鳴っている曲）の出口の盛り上がりから選ぶ。
  /// 曲頭のままでよい・材料が無い（音量の流れが未計測・切断点が決まらない）なら null。
  /// 出口 = 切断点の手前 1 段落の平均 dB。入り口は次曲の前半の段落（フレーズ）の頭から
  double? _smartEntryMs(PlaylistTrack next) {
    if (!_ref.read(smartEntryProvider)) return null;
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final outCurve = outItem?.energyDb;
    final inCurve = next.item.energyDb;
    if (outItem == null ||
        outCurve == null ||
        inCurve == null ||
        outItem.id == next.item.id) {
      return null;
    }
    final cut = _cutPoint()?.cut;
    if (cut == null) return null;
    const step = EnergyProfile.curveStepMs;
    final outGrid = outItem.beatGrid;
    final exitDb = EntryPlanner.exitDb(outCurve, cut.inMicroseconds / 1000,
        stepMs: step, grid: outGrid != null && outGrid.reliable ? outGrid : null);
    final inGrid = next.item.beatGrid;
    final sections = EntryPlanner.sections(
      inCurve,
      stepMs: step,
      grid: inGrid != null && inGrid.reliable ? inGrid : null,
      dropMs: next.item.mixInMs?.toDouble(),
      leadingSilenceMs: next.item.leadingSilenceMs ?? 0,
    );
    return EntryPlanner.entryMs(exitDb: exitDb, sections: sections);
  }

  /// 交差で入る曲の実際の開始位置: [effectiveStart] に拍合わせのずらし（±半拍）と、
  /// ジョグで手で動かした分（[jogMsFor]）を足したもの。
  /// [outStart] は出る曲の交差開始位置（省略時は予定の切断点から求める）、
  /// [inRate] は交差中の入る曲の速度。拍合わせができないときは effectiveStart のまま。
  /// 交差の開始・先読みの取り直し・重ね表示の組がすべてここを通るので、
  /// ジョグはここに入れておけば交差が始まるときに上書きされない
  Duration plannedInStart(PlaylistTrack next,
      {Duration? outStart, required double inRate}) {
    final raw = _plannedInStartRaw(next, outStart: outStart, inRate: inRate);
    final jog = jogMsFor(next);
    if (jog == 0) return raw;
    final shifted = raw + Duration(microseconds: (jog * 1000).round());
    return shifted < Duration.zero ? Duration.zero : shifted;
  }

  /// この次曲に効いているジョグの量（入る曲の媒体ミリ秒）。組が違えば 0
  double jogMsFor(PlaylistTrack next) {
    final j = _ref.read(jogOffsetProvider);
    if (j == null) return 0;
    return j.key == _pairKey(next) ? j.ms : 0;
  }

  /// この次曲に効いているテンポの微調整（±%）。組が違えば 0
  double tempoTrimFor(PlaylistTrack next) {
    final t = _ref.read(tempoTrimProvider);
    if (t == null) return 0;
    return t.key == _pairKey(next) ? t.percent : 0;
  }

  /// テンポの微調整を速度に掛ける比
  double _trimFactor(PlaylistTrack next) => 1 + tempoTrimFor(next) / 100;

  /// 今の曲から [next] へつなぐ組のキー（[MixPair.key] と同じ形）
  String _pairKey(PlaylistTrack next) => '${_armedFrom?.id}>${next.item.id}';

  Duration _plannedInStartRaw(PlaylistTrack next,
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

  /// プリロード側の次曲の交差中の速度（テンポ合わせ + 手の微調整）
  double _preloadInRate(PlaylistTrack next) {
    final base = preloadPlayer.state.rate;
    return (_tempoMatchedRate(next, base) ?? base) * _trimFactor(next);
  }

  /// この差より小さければシークし直さない
  static const _seekSlack = Duration(milliseconds: 15);

  /// 交差を途中から始めるとき、この差より小さければ「開始位置から」とみなす
  /// （監視の間隔と位置の報告の粗さぶん）
  static const _resumeSlack = Duration(milliseconds: 300);

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
    final oldSlot = _ref.read(activeSlotProvider);
    // 止めた状態で（重ね表示を押して）切り替えたら、新しい曲も止めたまま置く。
    // 交差中は入る曲がもう鳴っている。終端まで鳴り切った（completed）後の切り替えは鳴らす
    final wasPlaying = _crossfade != null ||
        oldPlayer.state.playing ||
        oldPlayer.state.completed;
    final newSlot = _ref.read(preloadSlotProvider);
    // 鳴っていた曲でも次の曲でもないスロット（前の曲をパーク中ならそこにいる）
    final spareSlot = ActiveSlot.values
        .firstWhere((s) => s != oldSlot && s != newSlot);
    _ref.read(activeSlotProvider.notifier).state = newSlot;

    // プロバイダ経由だと同一フレーム内で更新が反映されない場合があるため直接参照する
    final newPlayer = _ref.read(slotPlayerProvider(newSlot));

    // 交差中ならここで完了させる。監視は止める（次のプリロードで再び arm される）
    final session = _crossfade;
    _crossfade = null;
    final armed = _armedTrack;
    _armedTrack = null;
    _crossfadeMonitor?.cancel();
    _crossfadeMonitor = null;
    _ref.read(crossfadeProgressProvider.notifier).state = null;
    _ref.read(beatPhaseErrorProvider.notifier).state = null;
    final tapPair = _tapSwapPair;
    _tapSwapPair = null;

    // 切替点の瞬間の効果音（インパクト）はここで鳴らす
    session?.onCut();
    // 重ね表示の組（交差していた / 重ね表示で切替点より後を押した）。
    // 前曲は止めずにパークして、次に切り替わるまで開き直さずに行き来できるようにする。
    // パークした曲は 3 台目にいるので、次の曲の先読みは空いているスロットで続けられる
    final pair = armed == null
        ? null
        : session != null
            ? _pairAtSwap(
                outSlot: oldSlot,
                outDuration: oldPlayer.state.duration,
                next: armed,
                inDuration: newPlayer.state.duration,
                inStart: session.inStart,
                start: session.start,
                cut: session.cut,
                recipe: session.recipe,
                inRatio: session.inRatio,
                sfx: session.sfxPlan,
              )
            : tapPair;
    // その前にパークしていた曲（2 つ前の曲）はここで手放す。そのスロットが次の先読み先になる
    releaseParked();
    final park = pair != null &&
        canPark(oldPlayer.state.duration, newPlayer.state.duration);
    if (session != null) {
      session.finishIn();
      if (park) {
        // 曲線が 0 に着く前にスワップが来た場合も、短く落としてからポーズするのでぶつぎりにならない
        _parkPlayer(oldPlayer, pair);
        unawaited(_fadeOutAndPark(oldPlayer, session.outVolume, session.volume)
            .then((_) => session.clearOut()));
      } else {
        oldPlayer.stop();
        oldPlayer.setVolume(session.volume);
        session.clearOut();
      }
    } else {
      // 交差なしの切り替え: 新しい曲の大きさに合わせた音量にしてから鳴らす
      newPlayer.setVolume(
          _carryVolume(oldPlayer.state.volume, _armedFrom, armed?.item));
      if (park) {
        _parkPlayer(oldPlayer, pair);
        final volume = oldPlayer.state.volume;
        unawaited(_fadeOutAndPark(oldPlayer, volume, volume));
      } else {
        oldPlayer.stop();
      }
    }
    if (wasPlaying) {
      newPlayer.play();
    } else {
      newPlayer.pause();
    }
    // 次の曲の読み込み先: 前の曲を残すなら空いているスロット、残さないなら鳴っていた側
    _setPreloadSlot(park ? spareSlot : oldSlot);
    // テンポを寄せていた（拍合わせのナッジ込み）なら、前曲が消えた後にゆっくり本来の速度へ戻す
    if (session != null && session.appliedInRate != session.inBaseRate) {
      _startTempoRamp(
          session.inPlayer, session.appliedInRate, session.inBaseRate);
    }
    return newPlayer;
  }

  // --- 重ね表示の組と前曲のパーク ---
  //
  // 重ね表示は「1 曲目と 2 曲目をつないだ 1 本の時間軸」（[MixPair]、出る曲の時計）。
  // 切り替わる前は予定の交差から組を作り、交差して切り替わった後も前曲のプレイヤーは
  // 止めずにポーズで保持する（パーク）。重ね表示で前曲側をタップしたら、それを
  // 鳴らし直すだけで戻れる（開き直さない）。
  // パークは次に切り替わるまで続く。プレイヤーは 3 台あるので、パークしている間も
  // 空いているスロットで次の曲を先読みできる（2 曲目の間も前後の交差が両方出る）

  Player? _parkedPlayer;
  MixPair? _parkedPair;

  /// 重ね表示で切替点より後を押して起こす切り替え（交差の外から）。
  /// 次の [swapSlots] がこれを使って前曲をパークする
  MixPair? _tapSwapPair;

  /// 前曲のプレイヤーをパーク中か（この間はプリロード側を使わない）
  bool get hasParked => _parkedPlayer != null;

  /// パーク中の前曲の id（戻る先が本当にその曲か確かめる）
  String? get parkedItemId => _parkedPair?.outItem?.id;

  /// 重ね表示の組。前曲をパーク中ならその組、そうでなければ予定の交差から作る。
  /// 次曲が予約されていない・クロスフェードがオフなら null
  MixPair? mixPair() => parkedPair ?? plannedPair();

  /// パーク中の前曲との組（切り替わった後）。パークしていなければ null
  MixPair? get parkedPair => _parkedPair;

  /// 予定の交差から作る次曲との組（切り替わる前）。
  /// 次曲が予約されていない・クロスフェードがオフなら null
  MixPair? plannedPair() {
    final plan = plannedCrossfade();
    if (plan == null) return null;
    final session = _crossfade;
    final inStart = session?.inStart ??
        plannedInStart(plan.next,
            outStart: plan.start, inRate: _preloadInRate(plan.next));
    final outRate = activePlayer.state.rate;
    final inRatio = session?.inRatio ??
        (outRate > 0 ? _preloadInRate(plan.next) / outRate : 1.0);
    return _pairAtSwap(
      outSlot: _ref.read(activeSlotProvider),
      outDuration: activePlayer.state.duration,
      next: plan.next,
      inDuration: preloadPlayer.state.duration,
      inStart: inStart,
      start: plan.start,
      cut: plan.cut,
      recipe: plan.recipe,
      inRatio: inRatio,
      sfx: session?.sfxPlan ?? _sfxPlanFor(plan.recipe.effect, plan.start, plan.cut),
    );
  }

  MixPair _pairAtSwap({
    required ActiveSlot outSlot,
    required Duration outDuration,
    required PlaylistTrack next,
    required Duration inDuration,
    required Duration inStart,
    required Duration start,
    required Duration cut,
    required TransitionRecipe recipe,
    required double inRatio,
    SfxPlan? sfx,
  }) =>
      MixPair(
        outSlot: outSlot,
        outItem: _armedFrom,
        outDuration: outDuration,
        next: next,
        inDuration: inDuration,
        inStart: inStart,
        start: start,
        cut: cut,
        recipe: recipe,
        inRatio: inRatio,
        sfx: sfx,
      );

  /// 次の曲を読み込むスロットを決める。C は初めて使う前に映像の出力も作っておく
  /// （止まっている間に作らないと、表に出たときに頭に戻る）
  void _setPreloadSlot(ActiveSlot slot) {
    if (slot == ActiveSlot.c) _ref.read(controllerCProvider);
    _ref.read(preloadSlotProvider.notifier).state = slot;
  }

  /// 次曲の先読みを始めなければならない、終点までの残り時間（再生画面の先読み判定）。
  /// [endPoint] は曲の終点（1 番だけモードなら B 点）、[fade] はクロスフェードの長さ
  static Duration preloadLead({
    required LoopItem item,
    required Duration endPoint,
    required bool firstVerse,
    required Duration fade,
  }) {
    // 1 番だけモードでは早めに（30 秒前）
    var sec = firstVerse
        ? 30
        : endPoint.inSeconds > 120
            ? 30
            : 10;
    // クロスフェードは曲末の無音を除いた位置の fade 秒前から始まる。
    // それまでに先読みが済むよう、その分だけ早める
    if (fade > Duration.zero && !firstVerse) {
      final trailingSec = ((item.trailingSilenceMs ?? 0) / 1000).ceil();
      sec = max(sec, fade.inSeconds + trailingSec + 10);
    }
    return Duration(seconds: sec);
  }

  /// 前の曲を残す（3 台目を使う）曲の長さの上限。長い動画を 3 本開いたままにすると
  /// 重いので、どちらかがこれより長ければ前の曲は残さず 2 台で回す
  /// （戻るときは開き直す）。自動キャッシュで「長い曲」とする長さと同じ
  static const maxParkDuration = MediaCache.maxDuration;

  /// [outDuration] の曲を残したまま [inDuration] の曲を鳴らしてよいか（長さが不明なら残さない）
  static bool canPark(Duration outDuration, Duration inDuration) =>
      outDuration > Duration.zero &&
      inDuration > Duration.zero &&
      outDuration <= maxParkDuration &&
      inDuration <= maxParkDuration;

  void _parkPlayer(Player player, MixPair pair) {
    _parkedPlayer = player;
    _parkedPair = pair;
  }

  /// パークの記録だけ消す（プレイヤーは呼び出し側が使う）
  void _clearParked() {
    _parkedPlayer = null;
    _parkedPair = null;
  }

  /// パークをやめて前曲のプレイヤーを止める（次に切り替わった・別の曲へ移ったとき）
  void releaseParked() {
    _tapSwapPair = null;
    final player = _parkedPlayer;
    _clearParked();
    if (player == null) return;
    // すでにアクティブ側に戻っていたら止めない
    if (identical(player, activePlayer)) return;
    try {
      player.stop();
    } catch (e) {
      debugPrint('[PlaylistEngine] パークした前曲の停止に失敗: $e');
    }
  }

  /// 重ね表示で前曲側に戻るとき、パークした前曲のプレイヤーを [oldPos] から鳴らし直す。
  /// 今アクティブな次曲のプレイヤーはポーズしてプリロード側に戻す（そのまま次曲として使える）。
  /// その次の曲を読み込んでいたスロットは空ける。
  /// 戻り値は戻れたか（パークが切れていれば false → 呼び出し側は開き直す）
  bool stepBackToParked(Duration oldPos) {
    final parked = _parkedPlayer;
    if (parked == null || identical(parked, activePlayer)) return false;
    final nextPlayer = activePlayer;
    final nextSlot = _ref.read(activeSlotProvider);
    final parkedSlot = ActiveSlot.values
        .firstWhere((s) => identical(_ref.read(slotPlayerProvider(s)), parked));
    final staleSlot = _ref.read(preloadSlotProvider);
    // 止めた状態で戻ったら前曲も止めたまま
    final wasPlaying = nextPlayer.state.playing;
    _clearParked();
    _cancelTempoRamp();
    // その次の曲への交差の予約は成り立たない（呼び出し側が次曲で予約し直す）
    disarmCrossfade();
    unawaited(nextPlayer.pause());
    _ref.read(activeSlotProvider.notifier).state = parkedSlot;
    _setPreloadSlot(nextSlot);
    if (staleSlot != parkedSlot && staleSlot != nextSlot) {
      try {
        _ref.read(slotPlayerProvider(staleSlot)).stop();
      } catch (e) {
        debugPrint('[PlaylistEngine] その次の曲の停止に失敗: $e');
      }
    }
    // シークが済んでから鳴らす。パークした位置は切替点（曲の終端の 500ms 手前のことが多い）
    // なので、位置が動く前に鳴らすと LoopNotifier が曲終了とみなして、すぐ次曲へ戻してしまう
    unawaited(parked.seek(oldPos).then((_) {
      if (wasPlaying && identical(parked, activePlayer)) return parked.play();
      return null;
    }));
    return true;
  }

  /// 重ね表示の時間軸上の [t]（出る曲の時計）へ移る。押した位置に応じて鳴らし方を合わせる:
  /// - 出る曲が鳴っているとき: 切替点より前なら出る曲を動かす（交差の中なら入る曲も
  ///   描いた位置に合わせ、交差の手前なら監視が交差を取り消す）。切替点より後なら
  ///   入る曲をその位置に置いて、その場で切り替える（遷移は曲終了と同じ経路）
  /// - 入る曲が鳴っているとき: 切替点より後は入る曲を動かす。切替点より前へ戻るのは
  ///   プレイリストの状態も戻す必要があるので、画面側が [stepBackToParked] で行う
  void seekInPair(MixPair pair, Duration t) {
    final swapped = _ref.read(activeSlotProvider) != pair.outSlot;
    if (swapped) {
      if (t < pair.cut) return;
      unawaited(activePlayer.seek(_clampTo(pair.toInClock(t), pair.inDuration)));
      return;
    }
    if (t < pair.cut) {
      unawaited(activePlayer.seek(_clampTo(t, pair.outDuration)));
      final session = _crossfade;
      if (session != null && t >= session.start) session.resync(t);
      return;
    }
    // 切替点より後: 入る曲をその位置に置いて、その場で切り替える
    unawaited(
        preloadPlayer.seek(_clampTo(pair.toInClock(t), pair.inDuration)));
    final session = _crossfade;
    if (session != null) {
      if (session.advanced) return;
      session.advanced = true;
    } else {
      _tapSwapPair = pair;
    }
    _ref.read(loopProvider.notifier).onTrackEnd?.call();
  }

  static Duration _clampTo(Duration d, Duration max) {
    if (d < Duration.zero) return Duration.zero;
    if (max > Duration.zero && d > max) return max;
    return d;
  }

  /// 前曲を [from] から 150ms で 0 に落としてポーズする（止めない）。
  /// 戻ったときに鳴るよう、音量は [restore] に戻しておく
  Future<void> _fadeOutAndPark(Player player, double from, double restore) async {
    const steps = 3;
    try {
      for (var i = 1; i <= steps; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (identical(player, activePlayer)) return; // もう戻っていた
        await player.setVolume(from * (1 - i / steps));
      }
      if (identical(player, activePlayer)) return;
      await player.pause();
      await player.setVolume(restore);
    } catch (e) {
      debugPrint('[PlaylistEngine] 前曲のパークに失敗: $e');
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

  /// 予約中の次曲（プリロード側に載っていて、交差の予約が生きている曲）。無ければ null。
  /// 再生画面とミニプレイヤーの進行役が入れ替わるとき、先読みを捨てずに引き継ぐために見る
  PlaylistTrack? get armedTrack => _armedTrack;

  /// 予約したときに鳴っていた曲（スワップ時に音量正規化の補正をかけ直すため）
  LoopItem? _armedFrom;

  /// 音量正規化: [fromVolume] で鳴っている [from] から [to] に移るときの音量。オフならそのまま
  double _carryVolume(double fromVolume, LoopItem? from, LoopItem? to) {
    if (!_ref.read(volumeNormProvider)) return fromVolume;
    return Loudness.carry(fromVolume, from?.loudnessDb, to?.loudnessDb);
  }

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
    if (!keepCrossfade) {
      disarmCrossfade();
      releaseParked();
    }
  }

  /// リピートなしで最後の曲の終点（B 点）に達した。次の曲は無いので鳴らすのをやめ、
  /// 区間の頭（A 点か曲の頭）に戻しておく。B 点に置いたままだと、再生を押しても
  /// B 点の判定が済んだ扱いで区間の外を鳴らし続け、後からリピートを入れても次へ進めない。
  /// 前曲のパークはそのまま残す（重ね表示から戻れる）
  Future<void> pauseAtPlaylistEnd() async {
    final ls = _ref.read(loopProvider);
    final track = _ref.read(playlistPlayerProvider).currentTrack;
    final restart = (ls.enabled ? ls.pointA : null) ??
        Duration(milliseconds: track?.startMs ?? 0);
    try {
      await activePlayer.pause();
      await activePlayer.seek(restart);
    } catch (e) {
      debugPrint('[PlaylistEngine] プレイリストの終わりで止められない: $e');
    }
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

  /// 予定または進行中のクロスフェード区間（旧曲の時計で start〜cut）と次曲、つなぎ方。
  /// 次曲がプリロード済みでクロスフェードが有効なときだけ返す（ミックスビュー用）
  ({Duration start, Duration cut, PlaylistTrack next, TransitionRecipe recipe})?
      plannedCrossfade() {
    final next = _armedTrack;
    final fade = crossfadeDuration;
    if (next == null || fade == Duration.zero) return null;
    final session = _crossfade;
    if (session != null) {
      return (start: session.start, cut: session.cut, next: next, recipe: session.recipe);
    }
    final cutPoint = _cutPoint();
    if (cutPoint == null) return null;
    return (
      start: cutPoint.cut - fade,
      cut: cutPoint.cut,
      next: next,
      recipe: recipeFor(next),
    );
  }

  /// 次曲 [next] へのつなぎ方。おまかせがオンなら 2 曲の解析結果から選ぶ（TransitionPlanner）、
  /// オフなら手動の設定をまとめたもの。クロスフェードの設定が 0（オフ）ならどちらも長さ 0
  TransitionRecipe recipeFor(PlaylistTrack next) {
    final manualBeats = _ref.read(crossfadeProvider);
    final current = _ref.read(playlistPlayerProvider).currentTrack?.item;
    if (manualBeats > 0 && current != null && _ref.read(autoMixProvider)) {
      return TransitionPlanner.plan(current, next.item);
    }
    return TransitionRecipe(
      beats: manualBeats,
      curve: _ref.read(crossfadeCurveProvider),
      bassSwap: _ref.read(bassSwapProvider),
      effect: _ref.read(transitionEffectProvider),
      beatMatch: _ref.read(beatMatchProvider),
      tempoMatch: _ref.read(tempoMatchProvider),
    );
  }

  /// クロスフェードの長さ。設定は拍数（DJ は小節で数える）なので、出る曲の
  /// 実効テンポ（BPM × 速度）で秒にする。BPM が無い曲は 120 BPM とみなす（8 拍 = 4 秒）。
  /// おまかせのときの拍数は次曲が予約されてから決まる（それまでは手動の値）
  Duration get crossfadeDuration {
    final manual = _ref.read(crossfadeProvider);
    if (manual <= 0) return Duration.zero;
    final armed = _armedTrack;
    final beats = armed == null ? manual : recipeFor(armed).beats;
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
    _armedFrom = _ref.read(playlistPlayerProvider).currentTrack?.item;
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

  /// 今の演出で鳴らす効果音の予定（[start] 〜 [cut] の交差。出る曲の小節に合わせる）。
  /// 効果音を使わない演出なら null
  SfxPlan? _sfxPlanFor(TransitionEffect effect, Duration start, Duration cut) {
    if (!effect.usesSfx) return null;
    final grid = _ref.read(playlistPlayerProvider).currentTrack?.item.beatGrid;
    return SfxPlan.plan(
      effect: effect,
      startMs: start.inMicroseconds / 1000,
      cutMs: cut.inMicroseconds / 1000,
      outRate: activePlayer.state.rate,
      barMediaMs: grid != null && grid.reliable
          ? grid.periodMs * BeatGrid.beatsPerBar
          : null,
      variant: _sfxVariant,
    );
  }

  /// 出る曲の [fromMs] 〜 [to]（媒体）が実時間で何ミリ秒か
  int _realMs(double fromMs, Duration to) {
    final rate = activePlayer.state.rate;
    final ms = (to.inMicroseconds / 1000 - fromMs) / (rate > 0 ? rate : 1);
    return ms <= 0 ? 0 : ms.round();
  }

  /// 出る曲のいまの位置（媒体ミリ秒）。state.position は mpv からの報告なので 100ms ほど
  /// 遅れていることがある。効果音の予定（切替点までの残り時間）には mpv に直接聞いた値を使う
  Future<double> _precisePositionMs(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      try {
        final sec = double.tryParse(await platform.getProperty('time-pos'));
        if (sec != null && sec >= 0) return sec * 1000;
      } catch (_) {
        // 取れなければ報告された位置で
      }
    }
    return player.state.position.inMicroseconds / 1000;
  }

  /// 効果音を使う演出なら、プレイヤーを起こして音源を開いておく（交差の開始で待たないため）。
  /// 演出は交差を始めるときにもう一度読むので、ここで開いたものと違えばそのとき開き直す
  Future<void> _preloadSfx() async {
    final next = _armedTrack;
    if (next == null) return;
    final effect = recipeFor(next).effect;
    if (!effect.usesSfx) return;
    final planned = plannedCrossfade();
    final plan = planned == null
        ? _sfxPlanFor(effect, Duration.zero, crossfadeDuration)
        : _sfxPlanFor(effect, planned.start, planned.cut);
    if (plan == null) return;
    try {
      await _ref.read(transitionSfxProvider).load(plan.clips);
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
    _tapSwapPair = null;
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
        // アウトロの落ち込みは検出の誤差で少し前後するので、後ろのフレーズの頭も候補にする
        return _snapToGrid(item, (cut: cut, advancesAtCut: true),
            latestMs: (d - _minSilenceCut).inMicroseconds / 1000);
      }
    }
    final trailing = Duration(milliseconds: item?.trailingSilenceMs ?? 0);
    if (trailing < _minSilenceCut || trailing >= d) {
      return _snapToGrid(
          item, (cut: d - LoopNotifier.trackEndLead, advancesAtCut: false));
    }
    return _snapToGrid(item, (cut: d - trailing, advancesAtCut: true));
  }

  /// 切断点をフレーズの頭か小節頭へ寄せる（[snapCutMs]）。DJ は段落の区切りで切り替える。
  /// 格子が無い・信用できない曲はそのまま。[latestMs] より後ろへは動かさない（null なら手前だけ）。
  /// 動かしたら遷移はこちらから起こす
  ({Duration cut, bool advancesAtCut}) _snapToGrid(
      LoopItem? item, ({Duration cut, bool advancesAtCut}) raw,
      {double? latestMs}) {
    final grid = item?.beatGrid;
    if (grid == null || !grid.reliable) return raw;
    final rawMs = raw.cut.inMicroseconds / 1000;
    var snappedMs = snapCutMs(grid, rawMs,
        dropMs: item!.mixInMs?.toDouble(), allowLater: latestMs != null);
    if (latestMs != null && snappedMs > latestMs) {
      snappedMs = snapCutMs(grid, rawMs, dropMs: item.mixInMs?.toDouble());
    }
    final snapped = Duration(microseconds: (snappedMs * 1000).round());
    if (snapped <= Duration.zero ||
        (snapped - raw.cut).abs() <= const Duration(milliseconds: 1) ||
        activePlayer.state.position >= snapped) {
      return raw;
    }
    return (cut: snapped, advancesAtCut: true);
  }

  /// フレーズの頭が切断点の前後この小節数以内にあればそこへ寄せる。
  /// それより遠いと曲の終わりを大きく削るので、小節頭までにする
  static const maxPhraseSnapBars = 2;

  /// 切断点 [rawMs] をフレーズ（8 小節）の頭か小節頭へ寄せる（純粋関数）。
  ///
  /// フレーズの位置はドロップ [dropMs]（段落の頭）から数える。ドロップの前後
  /// [maxPhraseSnapBars] 小節以内にフレーズの頭があればそこ（[allowLater] が false なら手前だけ）、
  /// 無ければ直前の小節頭。ドロップが無い曲はフレーズの位置が分からないので小節頭まで
  static double snapCutMs(BeatGrid grid, double rawMs,
      {double? dropMs, bool allowLater = false}) {
    final bars = grid.barGrid(dropMs);
    final floorBar = bars.floorBeatMs(rawMs);
    if (dropMs == null) return floorBar;
    final phrases = grid.phraseGrid(dropMs);
    final before = phrases.floorBeatMs(rawMs);
    final limit = bars.periodMs * maxPhraseSnapBars + 1;
    if (rawMs - before <= limit) return before;
    final after = before + phrases.periodMs;
    if (allowLater && after - rawMs <= limit) return after;
    return floorBar;
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
      // 一時停止・巻き戻し（ABループでA点に戻った場合も）は取り消す。
      // 重ね表示で交差の中へ動かした直後は、位置の報告が落ち着くまで巻き戻しとみなさない
      // （シーク中の古い位置で取り消すと、入る曲が止まって頭に戻り、出る曲が一瞬大きく鳴る）
      if (!active.state.playing ||
          (pos < session.start && !session.settling)) {
        _cancelCrossfade();
        return;
      }
      final progress = session.step(pos);
      _ref.read(beatPhaseErrorProvider.notifier).state =
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
    final recipe = recipeFor(next);
    final inMatchedRate = _tempoMatchedRate(next, baseRate) ?? baseRate;
    final inRate = inMatchedRate * _trimFactor(next);
    final beat = _beatPlan(next, inRate);
    final inStart = plannedInStart(next, outStart: start, inRate: inRate);
    final curve = recipe.curve;
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
    final effect = recipe.effect;
    final volume = activePlayer.state.volume;
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final sfxPlan = _sfxPlanFor(effect, start, cut);
    final session = _CrossfadeSession(
      recipe: recipe,
      outPlayer: activePlayer,
      inPlayer: inPlayer,
      start: start,
      cut: cut,
      advancesAtCut: advancesAtCut,
      volume: volume,
      inVolume: _carryVolume(volume, outItem, next.item),
      inStart: inStart,
      inBaseRate: baseRate,
      inMatchedRate: inMatchedRate,
      inRate: inRate,
      curve: curve,
      // トリック系は切替点まで前の曲だけなので、低音の入れ替えはしない
      bassSwap: !effect.cutsHard && recipe.bassSwap,
      effect: effect,
      beat: beat,
      swapStartMs: swapStartMs,
      swapEndMs: swapEndMs,
      outRate: outRate,
      beatRealMs: beatRealMs,
      beatMediaMs: beatMs,
      sfx: sfxPlan != null ? _ref.read(transitionSfxProvider) : null,
      sfxPlan: sfxPlan,
      sfxVolume: TransitionSfx.volumeFor(volume, _ref.read(sfxLevelProvider)),
      sfxOffsetMs: _ref.read(sfxOffsetMsProvider),
      jogMs: jogMsFor(next),
      onForceCut: _forceCut,
    );
    _crossfade = session;
    try {
      if (beat != null) {
        debugPrint('[BeatMatch] 入る曲の開始 ${effectiveStart(next)} → $inStart '
            '(出 ${beat.outGrid} ×${beat.outRate} / 入 ${beat.inGrid} ×$inRate, '
            '合わせ続ける=${beat.lock})');
      }
      // 入る曲の位置。ふつうは armCrossfade で交差の開始位置に置いてあるので動かさない
      // （拍合わせのときだけ、ずれていれば置き直す）。
      // 交差の途中から始めるとき（重ね表示で交差の中へ戻った・飛んだ）は、その分だけ進めた位置に置く
      final offset = activePlayer.state.position - start;
      final midway = offset >= _resumeSlack;
      // 入る曲は速度が違う（テンポ合わせ）ので、進めた量もその比で
      final target = midway ? inStart + offset * session.inRatio : inStart;
      final slack = beat != null ? _seekSlack : _resumeSlack;
      if ((inPlayer.state.position - target).abs() >= slack) {
        await inPlayer.seek(target);
      }
      if (session.inRate != baseRate) await inPlayer.setRate(session.inRate);
      await inPlayer.setVolume(0);
      // 入る曲は低音を切った状態で重ね始める（鳴らす前に値を変えるので音切れしない）
      if (session.bassSwap) {
        await AudioFilters.setBassDb(inPlayer, AudioFilters.bassCutDb);
      }
      await inPlayer.play();
      // 効果音を開く（armCrossfade で同じものを開いてあれば一瞬で返る）
      if (session.sfx != null && sfxPlan != null) {
        await session.sfx!.load(sfxPlan.clips);
        _sfxVariant++;
      }
      // 効果音・トリックは実時間で予定する（切替点までの残り時間から）。
      // 位置は mpv に直接聞く（報告された位置は遅れていることがある）
      final posMs = await _precisePositionMs(activePlayer);
      if (_crossfade == session) {
        final toCutMs = _realMs(posMs, cut);
        session.startTricks(wallToCutMs: toCutMs);
        if (recipe.auto) debugPrint('[DjFx] おまかせ: $recipe');
        if (effect != TransitionEffect.none) {
          debugPrint('[DjFx] 演出 ${effect.name} 切替点まで ${toCutMs}ms '
              '1拍 ${beatRealMs.round()}ms 効果音 ${sfxPlan?.cues ?? const []} '
              '補正 ${session.sfxOffsetMs}ms '
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
    _ref.read(beatPhaseErrorProvider.notifier).state = null;
    session.rollback();
  }

  // --- 拍合わせ ---

  /// 拍合わせの計画。設定オンで両方の曲に拍の格子があるときだけ。
  /// 実効テンポ（倍/半を同一視）が 0.5% 以内で揃っていれば交差中も合わせ続ける（lock）。
  /// 揃っていなければ重ね始めの拍だけ揃える（ずれていくのは仕方ない）
  _BeatPlan? _beatPlan(PlaylistTrack next, double inRate) {
    if (!recipeFor(next).beatMatch) return null;
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

  // --- ジョグホイール（入る曲の拍の位置を手で合わせる） ---

  /// ジョグで動かせる幅（入る曲の媒体ミリ秒、片側）。小節頭の取り違えも直せるよう半小節。
  /// これより広いと自動の拍合わせの寄せ（±半小節）の外に出て、保存の計算が折り返す。
  /// 格子が無い・信用できない曲は null（手で合わせても自動が使わない）
  double? jogMaxMs(MixPair pair) {
    final grid = pair.next.item.beatGrid;
    if (grid == null || !grid.reliable) return null;
    return grid.periodMs * (BeatGrid.beatsPerBar / 2);
  }

  /// ジョグ中に見せる拍のずれ（実時間 ms、+ で入る曲が遅れている）。
  /// 交差中は実際に測った値（[beatPhaseErrorProvider]）、交差の前は組の開始位置
  /// （ジョグ込み）から出す予想値。測れないときは null
  double? jogErrorMs(MixPair pair) {
    if (_crossfade != null) return _ref.read(beatPhaseErrorProvider);
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final out = outItem?.beatGrid;
    final in_ = pair.next.item.beatGrid;
    if (out == null || in_ == null || !out.reliable || !in_.reliable) return null;
    final outRate = activePlayer.state.rate;
    final inRate = _preloadInRate(pair.next);
    if (outRate <= 0 || inRate <= 0) return null;
    return BeatMatcher.phaseErrorMs(
      out: out,
      in_: in_,
      outPosMs: activePlayer.state.position.inMicroseconds / 1000,
      outRate: outRate,
      inPosMs: pair.inStart.inMicroseconds / 1000,
      inRate: inRate,
    );
  }

  /// ジョグを音に効かせる。[jogMs] は入る曲を進める媒体ミリ秒（絶対値。
  /// 呼ぶ前に [jogOffsetProvider] へ入れておく）。
  /// 交差中は鳴っている入る曲を動かす（手で合わせている間は自動ナッジを止める）、
  /// 交差の前は止まっている次曲（プリロード）を予定の開始位置（ジョグ込み）へ置き直す
  void jog(MixPair pair, double jogMs, {required bool touching}) {
    final session = _crossfade;
    if (session != null) {
      session.applyJog(jogMs, touching: touching);
      return;
    }
    final target = plannedInStart(pair.next, inRate: _preloadInRate(pair.next));
    unawaited(preloadPlayer.seek(_clampTo(target, pair.inDuration)));
  }

  /// 重ね表示の下の棒（次曲）でのシーク。[u] は入る曲の時計。
  /// 切り替わった後は鳴っている入る曲を、交差中は重なって鳴っている入る曲を動かす。
  /// 交差の前は開始位置を決めるのは拍合わせとジョグなので、ここでは動かさない（false）
  bool seekInTrack(MixPair pair, Duration u) {
    final target = _clampTo(u, pair.inDuration);
    if (_ref.read(activeSlotProvider) != pair.outSlot) {
      unawaited(activePlayer.seek(target));
      return true;
    }
    final session = _crossfade;
    if (session == null) return false;
    session.seekIn(target);
    return true;
  }

  /// 手で合わせた分を入る曲の拍の格子に焼き込んで保存する（次回から自動がこの位置で合わせる）。
  /// 音はもう合っているので動かさない。拍の線は新しい格子で引き直される
  Future<void> saveJog(MixPair pair, double jogMs) async {
    final item = pair.next.item;
    final grid = item.beatGrid;
    if (grid == null || jogMs == 0) return;
    final shifted = grid.shiftedBy(jogMs);
    item.beatOffsetMs = shifted.offsetMs;
    item.downbeatMs = shifted.downbeatMs;
    _crossfade?.acceptJog();
    await _ref.read(loopItemsProvider.notifier).update(item);
  }

  // --- ピッチフェーダー（入る曲のテンポを手で合わせる） ---

  /// テンポの微調整を音に効かせる（[percent] は呼ぶ前に [tempoTrimProvider] へ入れておく）。
  /// 交差中は重なって鳴っている入る曲の速度をその場で変える。交差の前は次曲はまだ鳴って
  /// いないので、速度で変わる予定の開始位置だけ取り直す（速度は交差が始まるときに効く）
  void trimTempo(MixPair pair, double percent) {
    final session = _crossfade;
    debugPrint('[Deck] テンポ微調整 ${percent.toStringAsFixed(2)}% '
        '(${session != null ? '交差中' : '交差前'})');
    if (session != null) {
      session.applyTempoTrim(1 + percent / 100);
      return;
    }
    final target = plannedInStart(pair.next, inRate: _preloadInRate(pair.next));
    unawaited(preloadPlayer.seek(_clampTo(target, pair.inDuration)));
  }

  /// 手で合わせたテンポを入る曲の BPM に焼き込む: 速度を +p% して合ったなら、
  /// 本当の BPM は解析値 ÷ (1 + p/100)。格子は組の開始位置の拍を動かさずに引き直す。
  /// 音はもう合っているので動かさない（次回からは自動のテンポ合わせが同じ速度を出す）
  Future<void> saveTempo(MixPair pair, double percent) async {
    if (percent == 0) return;
    await _rescaleBpm(pair, 1 / (1 + percent / 100),
        anchorMs: pair.inStart.inMicroseconds / 1000);
    _crossfade?.acceptTempo();
  }

  Future<void> _rescaleBpm(MixPair pair, double factor,
      {required double anchorMs}) async {
    final item = pair.next.item;
    final grid = item.beatGrid;
    if (grid == null) return;
    final next = grid.withBpm(grid.bpm * factor, anchorMs: anchorMs);
    item.beatBpm = next.bpm;
    item.beatOffsetMs = next.offsetMs;
    item.downbeatMs = next.downbeatMs;
    // 表示・相性用の BPM（0.1 刻み）も同じ比で
    final bpm = item.bpm;
    if (bpm != null) item.bpm = (bpm * factor * 10).round() / 10;
    await _ref.read(loopItemsProvider.notifier).update(item);
  }

  /// 前曲が鳴っているテンポ（BPM × 速度）。BPM が無ければ null。円盤の下に出す
  double? outTempoBpm(MixPair pair) {
    final item = pair.outItem;
    final bpm = item?.beatBpm ?? item?.bpm;
    if (bpm == null) return null;
    return bpm * _ref.read(slotPlayerProvider(pair.outSlot)).state.rate;
  }

  /// 次曲のテンポ（BPM × 速度）。交差の前・交差中はテンポ合わせと微調整を入れた速度で
  /// （ナッジの一時的な速度は除く）、切り替わった後は鳴っている速度で
  double? inTempoBpm(MixPair pair) {
    final item = pair.next.item;
    final bpm = item.beatBpm ?? item.bpm;
    if (bpm == null) return null;
    final rate = _ref.read(activeSlotProvider) != pair.outSlot
        ? activePlayer.state.rate
        : _crossfade?.inRate ?? _preloadInRate(pair.next);
    return bpm * rate;
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

  /// 次曲に設定すべき速度。合わせない（設定オフ・不明・差が大きい）なら null。
  /// BPM は拍の格子の精密な値（板に出す数字と同じ）。差がどれだけ小さくても寄せる
  /// （数字まで揃え、交差中の拍合わせが常に効くように）。上限は ±[TrackCompatibility.maxTempoAdjustPercent]
  double? _tempoMatchedRate(PlaylistTrack next, double inBaseRate) {
    if (!recipeFor(next).tempoMatch) return null;
    final outItem = _ref.read(playlistPlayerProvider).currentTrack?.item;
    final outGrid = outItem?.beatGrid;
    final inGrid = next.item.beatGrid;
    // 格子が当てはまっていない曲はテンポも揺れている。寄せても合わないので触らない
    if (outGrid?.reliable == false || inGrid?.reliable == false) return null;
    final outBpm = outGrid?.bpm ?? outItem?.bpm;
    final inBpm = inGrid?.bpm ?? next.item.bpm;
    if (outBpm == null || inBpm == null) return null;
    final ratio = TrackCompatibility.tempoRatio(
        outBpm * activePlayer.state.rate, inBpm * inBaseRate);
    if (ratio == null) return null;
    if ((ratio - 1).abs() * 100 > TrackCompatibility.maxTempoAdjustPercent) {
      return null;
    }
    return inBaseRate * ratio;
  }

  /// 自動のテンポ合わせが次曲の速度に掛けた分（曲本来の速度からの ±%）。
  /// フェーダーのつまみの土台（手の微調整はこの上に足す）。交差の前は予定、交差中は
  /// 決めた値、切り替わった後は鳴っている速度（本来の速度へ戻るランプで 0 へ帰っていく）
  double autoTempoPercent(MixPair pair) {
    if (_ref.read(activeSlotProvider) != pair.outSlot) {
      final base = pair.next.item.speed;
      return base > 0 ? (activePlayer.state.rate / base - 1) * 100 : 0;
    }
    final session = _crossfade;
    if (session != null) {
      return (session.inMatchedRate / session.inBaseRate - 1) * 100;
    }
    final base = preloadPlayer.state.rate;
    if (base <= 0) return 0;
    return ((_tempoMatchedRate(pair.next, base) ?? base) / base - 1) * 100;
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
    required this.recipe,
    required this.outPlayer,
    required this.inPlayer,
    required this.start,
    required this.cut,
    required this.advancesAtCut,
    required this.volume,
    required this.inVolume,
    required this.inStart,
    required this.inBaseRate,
    required this.inMatchedRate,
    required this.inRate,
    required this.curve,
    required this.bassSwap,
    required this.effect,
    required this.beat,
    required this.swapStartMs,
    required this.swapEndMs,
    required this.outRate,
    required this.beatRealMs,
    required this.beatMediaMs,
    required this.sfx,
    required this.sfxPlan,
    required this.sfxVolume,
    required this.sfxOffsetMs,
    required this.onForceCut,
    required double jogMs,
  })  : outVolume = volume,
        appliedInRate = inRate,
        _jogMs = jogMs;

  /// ベーススワップにかける拍数（DJ の「一動作」。ゆっくり交差させない）
  static const bassSwapBeats = 2;

  /// この交差のつなぎ方（開始時に決めたもの。途中で設定が変わっても使い続ける）
  final TransitionRecipe recipe;

  /// 交差開始時の出る曲の速度。ブレーキで落とした後はこれに戻す
  final double outRate;

  /// 出る曲の 1 拍（実時間 / 媒体のミリ秒）
  final double beatRealMs;
  final double beatMediaMs;

  /// 効果音（使わない演出なら null）と、その音量（0〜100 の尺度）
  final TransitionSfx? sfx;
  final double sfxVolume;

  /// 効果音の予定（いつ・どれを・どの速度で）。重ね表示にも出す
  final SfxPlan? sfxPlan;

  /// 効果音のタイミングの補正（実時間 ms、+ で遅く）。設定で耳に合わせる分
  final int sfxOffsetMs;

  /// ライザーを伸び縮みさせたとき、続くインパクトのためにこの時間だけ前に素の速度へ戻す
  /// （ライザーの最後がわずかに速く／遅く鳴るだけ）
  static const rateResetLeadMs = 40;

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
    final s = sfx;
    final plan = sfxPlan;
    if (s != null && plan != null) {
      // 効果音は切替点からの相対で予定する（[SfxPlan] が出る曲の時計で決めた位置を実時間に）。
      // 音が出るまでの遅れの分だけ前倒し、設定の補正を足す
      final cutMs = cut.inMicroseconds / 1000;
      final latency = TransitionSfx.startLatencyMs.round();
      final lead = plan.lead;
      if (lead != null) {
        final leadRealMs = ((cutMs - lead.atMs) / outRate).round();
        _after(toCut - leadRealMs - latency + sfxOffsetMs, () {
          unawaited(s.start(volume: sfxVolume, rate: lead.rate));
          // スピンバックはレコードを巻き取る音なので、曲はすぐ消す
          if (effect == TransitionEffect.spinback) _killOut();
        });
        // 伸び縮みさせたライザーに続けて鳴るインパクトは素の速度で
        if (lead.rate != 1 && plan.impact != null) {
          _after(toCut - rateResetLeadMs + sfxOffsetMs, () => unawaited(s.setRate(1)));
        }
      } else if (plan.impact != null) {
        // インパクト単独も切替点に合わせて予定する。以前は実際の切り替え（スワップ）で鳴らして
        // いたが、スワップは曲の終わりの検出や 100ms ごとの監視を待つので遅れ、前の曲が
        // 終わってから鳴っていた
        _after(toCut - latency + sfxOffsetMs, _fireImpact);
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
    // 予定より早く切り替わった（重ね表示で切替点より後を押した・トリックで切った）ときだけ、ここで鳴らす
    if (effect.impactAtCut && effect.leadInSfx == null) _fireImpact();
  }

  bool _impactFired = false;

  /// インパクト単独を 1 回だけ鳴らす
  void _fireImpact() {
    if (_impactFired) return;
    _impactFired = true;
    unawaited(sfx?.start(volume: sfxVolume));
  }

  /// ベーススワップの開始・終了位置（出る曲の媒体ミリ秒）。開始は拍の頭に寄せてある。
  /// 演出（スイープ）も開始位置から切替点にかけて
  final double swapStartMs;
  final double swapEndMs;

  /// 拍合わせの計画（しないときは null）
  final _BeatPlan? beat;

  /// 直近に入る曲へ設定した速度（テンポ合わせ + ナッジ）。交差後はここから本来の速度へ戻す
  double appliedInRate;

  /// ジョグで動かした量（入る曲の媒体ミリ秒）。[applyJog] が差分だけ入る曲をシークする。
  /// 交差を始めたときの量から数える（開始位置にはもう入っているので、二重に効かせない）
  double _jogMs;

  /// 重なって鳴っている入る曲を [u] へ動かす（下の棒でのシーク）。測定は少し待つ
  void seekIn(Duration u) {
    unawaited(inPlayer.seek(u));
    _nudgeHoldUntil = DateTime.now().add(const Duration(milliseconds: 400));
  }

  /// 手でジョグを回している間は自動ナッジ（速度の寄せ）を止める。ずれの測定は続ける
  bool jogging = false;

  /// ジョグを音に効かせる。[jogMs] は絶対量。前回との差だけ入る曲をシークする
  void applyJog(double jogMs, {required bool touching}) {
    jogging = touching;
    final delta = jogMs - _jogMs;
    _jogMs = jogMs;
    if (delta.abs() < 1) return;
    final pos = inPlayer.state.position;
    unawaited(inPlayer.seek(pos + Duration(microseconds: (delta * 1000).round())));
    // シーク直後の位置は信用できないので少し測定を待つ
    _nudgeHoldUntil = DateTime.now().add(const Duration(milliseconds: 250));
  }

  /// 保存したので、動かした量を基準に戻す（音は動かさない）
  void acceptJog() {
    _jogMs = 0;
    jogging = false;
  }

  double _errSmooth = 0;
  int _nudgeTicks = 0;
  bool _measuring = false;
  DateTime? _nudgeHoldUntil;
  DateTime? _settleUntil;

  /// [resync] の直後で、出る曲の位置の報告がまだ信用できない間
  bool get settling {
    final until = _settleUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 出る曲を交差の中の [outPos] へ動かしたとき、入る曲も同じ時間軸の位置に合わせる。
  /// 出る曲の媒体時間 1ms あたり、入る曲の媒体時間が進む量（テンポ合わせで速度が違う）
  double get inRatio => outRate > 0 ? inRate / outRate : 1;

  /// 拍合わせは測り直す（シークが済むまでの位置は信用できないので少し待つ）
  void resync(Duration outPos) {
    final offset = outPos - start;
    unawaited(inPlayer.seek(
        offset > Duration.zero ? inStart + offset * inRatio : inStart));
    _measuring = false;
    _nudgeTicks = 0;
    _errSmooth = 0;
    final now = DateTime.now();
    _nudgeHoldUntil = now.add(const Duration(milliseconds: 400));
    _settleUntil = now.add(const Duration(seconds: 1));
    if (appliedInRate != inRate) {
      appliedInRate = inRate;
      unawaited(inPlayer.setRate(inRate));
    }
  }

  /// 交差中の拍合わせ: 両プレイヤーの位置から位相のずれを測り、入る曲の速度で寄せる。
  /// play() 直後は位置が動き出すまで待つ（開始遅延はこの測定で吸収される）。
  /// 戻り値は測ったずれ（平滑後、実時間 ms）。測れないときは null。
  /// テンポが揃わず合わせ続けない組（lock でない）も、ずれは測って返す（寄せはしない）
  double? nudgeBeats(Duration outPos) {
    final plan = beat;
    // トリック中は出る曲の位置が遅くなる・戻るので、位相を測っても意味がない
    if (plan == null || effect.cutsHard) return null;
    final hold = _nudgeHoldUntil;
    if (hold != null && DateTime.now().isBefore(hold)) return null;
    final inPos = inPlayer.state.position;
    if (!_measuring) {
      if (inPos <= inStart) return null;
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
    if (!plan.lock || jogging) return _errSmooth;
    final target = inRate * (1 + BeatMatcher.rateAdjust(_errSmooth));
    if ((target - appliedInRate).abs() >= 0.0005) {
      appliedInRate = target;
      unawaited(inPlayer.setRate(target));
    }
    if (_nudgeTicks % 10 == 1) {
      debugPrint('[BeatMatch] 位相誤差 ${err.toStringAsFixed(0)}ms '
          '(平滑 ${_errSmooth.toStringAsFixed(0)}ms) → rate ${target.toStringAsFixed(4)}');
    }
    return _errSmooth;
  }

  /// つなぎ方（音量曲線）。開始時の設定を交差の間は使い続ける
  final CrossfadeCurve curve;

  /// ベーススワップをするか。開始時に入る曲の低音を切り、[CrossfadeCurve.bassSwapAt] で
  /// 出る曲の低音を切って入る曲の低音を戻す
  final bool bassSwap;

  /// 出る曲にかける演出。ベーススワップと同じ位置から切替点までかける
  final TransitionEffect effect;

  final Player outPlayer;
  final Player inPlayer;
  final Duration start;
  final Duration cut;

  /// 切断点が曲の終端より手前（曲末の無音を飛ばす）なので、到達時に遷移を起こす
  final bool advancesAtCut;
  bool advanced = false;

  final double volume;

  /// 入る曲の交差後の音量（音量正規化で出る曲と違うことがある）
  final double inVolume;

  /// 取り消し時に新プレイヤーを戻す位置（次曲のA点）
  final Duration inStart;

  /// 次曲本来の速度と、交差中にテンポを寄せた速度（寄せないときは同じ値）
  final double inBaseRate;

  /// テンポ合わせで決めた入る曲の速度（手の微調整を除く）。微調整はこれに掛ける
  double inMatchedRate;

  /// 入る曲の目標速度（テンポ合わせ × 微調整）。ナッジはこの周りで寄せる
  double inRate;

  /// ピッチフェーダーを音に効かせる。[factor] はテンポ合わせの速度に掛ける比
  void applyTempoTrim(double factor) {
    final next = inMatchedRate * factor;
    if ((next - inRate).abs() < 0.0005) return;
    inRate = next;
    appliedInRate = next;
    unawaited(inPlayer.setRate(next));
  }

  /// テンポを保存したので、今の速度を基準に戻す（音は動かさない）
  void acceptTempo() {
    inMatchedRate = inRate;
  }

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
    inPlayer.setVolume(inVolume * levels.in_);

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
    inPlayer.setVolume(inVolume);
    if (bassSwap) unawaited(AudioFilters.reset(inPlayer));
  }

  /// 出る曲のトリックを初期状態に戻す（停止した後に呼ぶ。次にプリロード側として使うため）。
  /// フィルタは止めた後なので値は戻さず、状態だけ忘れる（次に開く前の detach で外れる）
  void clearOut() {
    _cancelTricks();
    AudioFilters.forget(outPlayer);
    unawaited(DeckTricks.reset(outPlayer));
    if (effect == TransitionEffect.brake) unawaited(outPlayer.setRate(outRate));
  }

  /// 取り消し。新プレイヤーを頭に戻して待機状態へ。効果音も止める
  void rollback() {
    _cancelTricks();
    unawaited(sfx?.stop());
    inPlayer.pause();
    inPlayer.seek(inStart);
    inPlayer.setVolume(inVolume);
    if (appliedInRate != inBaseRate) inPlayer.setRate(inBaseRate);
    outPlayer.setVolume(volume);
    if (bassSwap) unawaited(AudioFilters.reset(inPlayer));
    clearOut();
  }
}

/// 重ね表示の 1 組: 1 曲目（出る曲）と 2 曲目（入る曲）をつないだ 1 本の時間軸。
/// 時刻は出る曲の時計（入る曲の時計との換算は [toOutClock] / [toInClock]）。
/// 切り替わる前（予定の交差）も後（前曲をパーク中）も同じ形で持ち、
/// どちらが鳴っているかは [outSlot] と activeSlotProvider を見比べて決める
class MixPair {
  const MixPair({
    required this.outSlot,
    required this.outItem,
    required this.outDuration,
    required this.next,
    required this.inDuration,
    required this.inStart,
    required this.start,
    required this.cut,
    required this.recipe,
    this.inRatio = 1,
    this.sfx,
  });

  /// 出る曲の時計 1ms あたり、入る曲の時計が進む量（入る曲の速度 ÷ 出る曲の速度）。
  /// テンポ合わせで入る曲の速度を変えると 1 ではなくなる。重ね表示の下段と拍の線を
  /// 実際の鳴り方と揃えるのに使う（1 のまま描くと拍の線が少しずつずれて見えた）
  final double inRatio;

  /// 出る曲が載っているスロット
  final ActiveSlot outSlot;
  final LoopItem? outItem;
  final Duration outDuration;

  /// 入る曲
  final PlaylistTrack next;
  final Duration inDuration;

  /// 入る曲が鳴り始める位置（入る曲の時計。曲頭の無音や A 点、拍合わせのずらしの後）
  final Duration inStart;

  /// 交差の開始と切替点（出る曲の時計）
  final Duration start;
  final Duration cut;

  /// つなぎ方（曲線・低音の印・おまかせの説明）
  final TransitionRecipe recipe;

  /// 効果音の予定（ライザーの始まり・インパクトの位置を重ね表示に描く）。使わなければ null
  final SfxPlan? sfx;

  /// 入る曲の時計 → 出る曲の時計
  Duration toOutClock(Duration inPos) =>
      start + (inPos - inStart) * (1 / inRatio);

  /// 出る曲の時計 → 入る曲の時計
  Duration toInClock(Duration t) => inStart + (t - start) * inRatio;

  /// 組の見分け（画面側が手動の表示切替を覚えておく単位）
  String get key => '${outItem?.id}>${next.item.id}';
}
