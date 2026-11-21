import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/audio/audio_quality.dart';
import '../../models/loop_item.dart';
import '../../providers/data_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_player_provider.dart';
import '../../providers/provider_reader.dart';
import '../audio_filters.dart';
import '../cache_service.dart';
import '../deck_tricks.dart';
import '../youtube_service.dart';
import 'hq_audio.dart';
import 'media_cache.dart';
import 'unplayable_watch.dart';

/// どこから開いたか
enum MediaOrigin {
  /// オフライン保存したファイル
  offline,

  /// YouTube（自動キャッシュに残っている映像か、ストリーム）
  youtube,

  /// 端末の動画・音声ファイル
  local,
}

/// [MediaOpener.open] で開いたもの
class OpenedMedia {
  const OpenedMedia({required this.uri, required this.origin, this.manifest});

  /// プレイヤーに渡した URI（ファイルのパスかストリームの URL）
  final String uri;
  final MediaOrigin origin;

  /// YouTube をネットから開いたときのマニフェスト（波形用の音声の先読みに使う）。
  /// オフライン保存・自動キャッシュ・ローカルは null
  final StreamManifest? manifest;
}

/// 曲をプレイヤーに開いて、鳴らせる状態にする手順（まだ再生はしない）。
///
/// 再生画面で曲を開く [PlayerLoader] と、プレイリストの先読み・遷移の
/// PlaylistEngine.prepare の両方がこれを通す（以前は同じ手順の 2 実装で、
/// 片方だけ直す事故の元だった）。
/// 1. 前の曲の名残（音声フィルタ・ブレーキやループロール）を外す
/// 2. オフライン保存 → 自動キャッシュの映像 → YouTube のマニフェスト（再生できない動画は
///    [UnplayableWatch] が曲に残す）→ ローカルのファイル、の順に開くものを決めて開く
/// 3. duration が取れるまで無音で短く鳴らす（0 のままだとループ監視も終端検知も働かない）
/// 4. 高音質の音声を待って付ける（間に合わなければ落ち次第、同じ曲のままなら付け替える）
/// 5. 開始位置へシークし、**毎回**速度を設定する（プレイヤーを使い回すので前の曲の速度が残る）
/// 6. 音声フィルタを付ける（再生中には付けられない。交差中は値だけ動かす）
///
/// [isCancelled] が true になったら（画面を離れた・曲が変わった）途中でやめて null を返す。
/// [onStep] には進み具合（0〜1）と文を渡す（再生画面の読み込みの表示）
class MediaOpener {
  MediaOpener(
    this._read, {
    required this.isCancelled,
    this.onStep,
    this.logTag = '',
  });

  final ProviderReader _read;
  final bool Function() isCancelled;
  final void Function(double value, String text)? onStep;

  /// 高音質のログの頭に付ける名前（どちらの経路から開いたか）
  final String logTag;

  /// [open] の downloadFirst で映像を落とし切るのを待つ上限。超えたらストリーミングで開く
  static const videoDownloadWait = Duration(seconds: 30);

  /// [item] を [player] に開く。
  /// - [startAt]: 最後にシークする位置（開いた後に決まるものもあるので関数で受ける）
  /// - [downloadFirst]: 自動キャッシュに無い YouTube の映像を落としてから開く（プリロード。
  ///   時間に余裕がある）。false ならストリーミングで開き、少し後に裏で落とす
  /// - [metadataWait]: duration が取れるまで待つ上限
  /// - [hqAudioWait]: 高音質の音声を待つ上限
  /// - [streamOpenTimeout]: YouTube を開くときの打ち切り（null なら打ち切らない）
  /// - [onOpened]: `player.open` の直後（メタデータ待ちの前）。待たせたくない裏の仕事に
  Future<OpenedMedia?> open(
    Player player,
    LoopItem item, {
    required Duration Function() startAt,
    required Duration metadataWait,
    required Duration hqAudioWait,
    bool downloadFirst = false,
    bool waitForMetadata = true,
    Duration? streamOpenTimeout,
    void Function(OpenedMedia media)? onOpened,
  }) async {
    // 作れない列のフィルタが付いたまま開くと、その曲の音声が無効になる
    await AudioFilters.detach(player);
    await DeckTricks.reset(player);

    final quality = _read(audioQualityProvider.notifier);
    // 高音質の音声（音声専用ストリーム）。開くのと並行して落とし、メタデータ確定後に付ける
    Future<String?>? hqAudio;
    final OpenedMedia media;
    final offline = CacheService.offlineVideoPath(item);
    if (offline != null) {
      // オフライン保存済み: 通信なしでローカルファイルを再生
      quality.set(player, AudioQuality.offline);
      _step(0.40, 'オフラインキャッシュを読み込み中...');
      media = OpenedMedia(uri: offline, origin: MediaOrigin.offline);
      _step(0.70, 'プレーヤーを準備中...');
      await player.open(Media(offline), play: false);
    } else if (item.isYouTube && item.videoId != null) {
      final videoId = item.videoId!;
      StreamManifest? manifest;
      // 自動キャッシュに映像が残っていれば通信なしで開く（マニフェストも取らない）
      var local = await MediaCache.existingVideo(videoId);
      if (local != null) {
        _step(0.40, 'キャッシュから読み込み中...');
      } else {
        _step(0.15, 'ストリーム情報を解析中...');
        // 年齢制限などで開けない曲は残して、プレイリストでは飛ばす
        manifest = await UnplayableWatch.fetch<StreamManifest>(
            _read(loopItemsProvider.notifier),
            _read(playlistPlayerProvider.notifier),
            item,
            () => _read(youtubeServiceProvider).getManifestWithFallback(videoId));
        await _yieldFrame();
        if (isCancelled()) return null;
      }
      if (HqAudio.enabled) {
        // 開くのと並行して落とす。波形の先読みも同じファイルを使う（HqAudio が 1 回にまとめる）
        HqAudio.log('$logTag: 取得を依頼');
        hqAudio = HqAudio.fetch(videoId,
            manifest: manifest, isCancelled: isCancelled);
      } else {
        HqAudio.log('$logTag: 高音質はオフ（設定）');
      }
      if (local == null) {
        if (downloadFirst) {
          local = await MediaCache.fetchVideo(videoId, manifest!,
                  isCancelled: isCancelled)
              .timeout(videoDownloadWait, onTimeout: () => null);
          if (isCancelled()) return null;
        } else {
          // 再生が落ち着いてから裏で映像を残す（次回から通信なし）
          MediaCache.cacheVideoLater(videoId, manifest!,
              isCancelled: isCancelled);
        }
      }
      media = OpenedMedia(
        uri: local ?? YouTubeService.pickStreamUrl(manifest!),
        origin: MediaOrigin.youtube,
        manifest: manifest,
      );
      quality.set(player, AudioQuality.standard);
      _step(0.50, 'プレーヤーを準備中...');
      final opening = player.open(Media(media.uri), play: false);
      await (streamOpenTimeout == null
          ? opening
          : opening.timeout(streamOpenTimeout));
    } else {
      quality.set(player, AudioQuality.local);
      _step(0.30, 'ファイルを読み込み中...');
      media = OpenedMedia(uri: item.uri, origin: MediaOrigin.local);
      _step(0.65, 'プレーヤーを準備中...');
      await player.open(Media(item.uri), play: false);
    }
    onOpened?.call(media);
    await _yieldFrame();
    if (isCancelled()) return null;

    if (waitForMetadata) {
      await _waitForMetadata(player, metadataWait);
      if (isCancelled()) return null;
    }
    if (hqAudio != null) {
      await _attachHqAudio(player, hqAudio, hqAudioWait, quality);
      if (isCancelled()) return null;
    }

    await player.seek(startAt());
    await player.setRate(item.speed);
    await AudioFilters.install(player);
    return media;
  }

  void _step(double value, String text) => onStep?.call(value, text);

  /// duration が取れるまで無音で短く鳴らす
  Future<void> _waitForMetadata(Player player, Duration wait) async {
    if (player.state.duration != Duration.zero) return;
    _step(0.90, 'メタデータを取得中...');
    // 鳴っている側の音量に戻す（先読み側は前の曲のフェードで 0 のままのことがある。
    // 再生画面で開くときは開く側が鳴っている側なので、元の音量に戻る）
    final restore = _read(playerProvider).state.volume;
    await player.setVolume(0);
    await player.play();
    const step = Duration(milliseconds: 100);
    for (var i = 0;
        i < wait.inMilliseconds ~/ step.inMilliseconds &&
            player.state.duration == Duration.zero &&
            !isCancelled();
        i++) {
      await Future.delayed(step);
    }
    await player.pause();
    await player.setVolume(restore);
    await _yieldFrame();
  }

  /// 高音質の音声が [wait] までに落ちていれば付ける。
  /// 間に合わなければ一体型の音声で始め、落ち次第まだ同じ曲を開いていれば途中で付け替える
  /// （一瞬途切れるが、その回ずっと 96kbps で聴くよりよい）。
  /// [quality] は先に受け取っておく（後から付けるときは画面が無くて ref を読めないことがある）
  Future<void> _attachHqAudio(Player player, Future<String?> hqAudio,
      Duration wait, AudioQualityNotifier quality) async {
    _step(0.95, '高音質の音声を取得中...');
    var timedOut = false;
    final path = await hqAudio.timeout(wait, onTimeout: () {
      timedOut = true;
      return null;
    });
    if (isCancelled()) {
      HqAudio.log('$logTag: 曲が変わったので付けない');
      return;
    }
    if (timedOut) {
      HqAudio.log('$logTag: ${wait.inSeconds} 秒に間に合わず、落ち次第付ける');
      // プレイヤーが持っている形の URI で比べる（Media は URI を正規化するので、
      // 渡した文字列と比べると同じ曲でも違うと判定することがある）
      final opened = player.state.playlist.medias.firstOrNull?.uri;
      unawaited(hqAudio.then((late) async {
        if (late == null) return;
        if (isCancelled() ||
            player.state.playlist.medias.firstOrNull?.uri != opened) {
          HqAudio.log('$logTag: 落ちたが曲が変わっていたので付けない');
          return;
        }
        await _attach(player, late, quality);
      }));
      return;
    }
    if (path == null) {
      HqAudio.log('$logTag: 落とせなかったので一体型のまま');
      return;
    }
    HqAudio.log('$logTag: 取り付けへ');
    await _attach(player, path, quality);
    await _yieldFrame();
  }

  Future<void> _attach(
      Player player, String path, AudioQualityNotifier quality) async {
    if (await HqAudio.attach(player, path)) {
      quality.set(player, AudioQuality.hq(HqAudio.labelFor(path)));
    }
  }

  /// 重い await の後に 1 フレーム描画の隙間を作る
  static Future<void> _yieldFrame() =>
      Future.delayed(const Duration(milliseconds: 2));
}
