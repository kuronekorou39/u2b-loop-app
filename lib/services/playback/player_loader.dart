import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/audio/audio_quality.dart';
import '../../models/loop_item.dart';
import '../../models/video_source.dart';
import '../../providers/player_provider.dart';
import '../audio_filters.dart';
import '../cache_service.dart';
import '../youtube_service.dart';
import 'hq_audio.dart';
import 'media_cache.dart';
import 'load_progress.dart';

/// 開いたメディア。[manifest] は YouTube をネットから開いたときだけ
/// （波形用の音声を先読みするのに使う。オフライン保存・ローカルは null）
class LoadedMedia {
  const LoadedMedia({required this.source, this.manifest});

  final VideoSource source;
  final StreamManifest? manifest;
}

/// 画面を離れたので読み込みを途中で打ち切った。
/// 呼び出し側は mounted を見てから setState するので、握りつぶしてよい
class LoadAborted implements Exception {
  const LoadAborted();

  @override
  String toString() => 'LoadAborted';
}

/// 再生画面と AB 設定画面で同じ手順で曲を開く。
///
/// 進捗を進めながら
/// 1. オフライン保存があればそのファイル / YouTube はマニフェストを解決 / ローカルはそのまま
/// 2. `player.open`（YouTube は [openTimeout] で打ち切り）
/// 3. duration が取れるまで無音で短く再生してメタデータを確定させる
///    （0 のままだとループ監視も終端検知も働かない）
/// 4. 高音質の音声を付ける
/// 5. **毎回**速度を設定する（プレイヤーを使い回すので、前の曲の速度が残る）
/// 6. 最後に videoSourceProvider に流す（これを見てコントローラーが押せるようになる）
///
/// プレイリストの遷移（プリロード側）は PlaylistEngine.prepare が同じことをする。
/// 直す時は両方を見ること
class PlayerLoader {
  PlayerLoader(this._ref, {required this.progress, required this.isMounted});

  final WidgetRef _ref;
  final LoadProgress progress;
  final bool Function() isMounted;

  static const openTimeout = Duration(seconds: 60);

  /// 高音質の音声（数 MB）を待つ上限。開く+メタデータ待ちと並行して落ちているので、
  /// 普通の回線ならここで待つのは残りだけ
  static const hqAudioWait = Duration(seconds: 8);

  /// この曲をどのソースとして開くか（純粋な計算。テストしやすいように分けてある）。
  /// [offlinePath] があれば種別は youtube のまま URI だけローカルファイル
  /// （字幕や UI の分岐を YouTube として扱うため）
  static VideoSource sourceFor(LoopItem item,
      {String? offlinePath, String? streamUrl}) {
    if (offlinePath != null) {
      return VideoSource(
        type: VideoSourceType.youtube,
        uri: offlinePath,
        title: item.title,
        videoId: item.videoId,
        thumbnailUrl: item.thumbnailUrl,
      );
    }
    if (item.isYouTube) {
      assert(streamUrl != null, 'YouTube を開くには streamUrl が要る');
      return VideoSource(
        type: VideoSourceType.youtube,
        uri: streamUrl!,
        title: item.title,
        videoId: item.videoId,
        thumbnailUrl: item.thumbnailUrl,
      );
    }
    return VideoSource(
      type: VideoSourceType.local,
      uri: item.uri,
      title: item.title,
    );
  }

  /// [item] を開いて再生できる状態にする（まだ再生はしない）。
  /// [onOpened] は `player.open` の直後（メタデータ待ちの前）に呼ぶ。
  /// 波形の音声先読みなど、待たせたくない裏の仕事を始めるのに使う
  Future<LoadedMedia> load(LoopItem item,
      {void Function(LoadedMedia media)? onOpened}) async {
    try {
      final player = _ref.read(playerProvider);
      // 音声フィルタは外して開く（PlaylistEngine.prepare と同じ。付けるのは交差の予約時）
      await AudioFilters.detach(player);
      final offline = CacheService.offlineVideoPath(item);
      final LoadedMedia media;
      Future<String?>? hqAudio;
      final quality = _ref.read(audioQualityProvider.notifier);
      if (offline != null) {
        // オフライン保存済み: 通信なしでローカルファイルを再生
        quality.set(player, AudioQuality.offline);
        progress.step(0.40, 'オフラインキャッシュを読み込み中...');
        media = LoadedMedia(source: sourceFor(item, offlinePath: offline));
        progress.step(0.70, 'プレーヤーを準備中...');
        await player.open(Media(offline), play: false);
      } else if (item.isYouTube) {
        final videoId = item.videoId!;
        // 自動キャッシュに映像が残っていれば通信なしで開く（マニフェストも取らない）
        final local = await MediaCache.existingVideo(videoId);
        StreamManifest? manifest;
        if (local != null) {
          progress.step(0.40, 'キャッシュから読み込み中...');
        } else {
          progress.step(0.15, 'ストリーム情報を解析中...');
          manifest = await _ref
              .read(youtubeServiceProvider)
              .getManifestWithFallback(videoId);
          await _yieldFrame();
          _checkMounted();
          // 再生が落ち着いてから裏で映像を残す（次回から通信なし）
          MediaCache.cacheVideoLater(videoId, manifest,
              isCancelled: () => !isMounted());
        }
        media = LoadedMedia(
          source: sourceFor(item,
              streamUrl: local ?? YouTubeService.pickStreamUrl(manifest!)),
          manifest: manifest,
        );
        if (HqAudio.enabled) {
          // 開くのと並行して落とす。波形の先読みも同じファイルを使う（HqAudio が 1 回にまとめる）
          HqAudio.log('ローダー: 取得を依頼');
          hqAudio = HqAudio.fetch(videoId,
              manifest: manifest, isCancelled: () => !isMounted());
        }
        quality.set(player, AudioQuality.standard);
        progress.step(0.50, 'プレーヤーを準備中...');
        await player
            .open(Media(media.source.uri), play: false)
            .timeout(openTimeout);
      } else {
        quality.set(player, AudioQuality.local);
        progress.step(0.30, 'ファイルを読み込み中...');
        media = LoadedMedia(source: sourceFor(item));
        progress.step(0.65, 'プレーヤーを準備中...');
        await player.open(Media(item.uri), play: false);
      }
      onOpened?.call(media);
      await _yieldFrame();
      _checkMounted();

      await _waitForMetadata(player);
      _checkMounted();
      await _attachHqAudio(player, hqAudio, media);
      _checkMounted();
      await player.setRate(item.speed);
      // ここで初めてソースを公開する。画面のコントローラーはこれを見て押せるようになるので、
      // メタデータ待ちや音声の取り付けの最中に操作されない
      _ref.read(videoSourceProvider.notifier).state = media.source;
      return media;
    } catch (_) {
      progress.end();
      rethrow;
    }
  }

  /// 進捗を満たして終える。呼び出し側はこの後で動画枠を再生に切り替える
  void finish() {
    _checkMounted();
    progress.step(1.0, '読み込み完了');
    progress.end();
  }

  Future<void> _waitForMetadata(Player player) async {
    if (player.state.duration != Duration.zero) return;
    progress.step(0.90, 'メタデータを取得中...');
    final prevVolume = player.state.volume;
    await player.setVolume(0);
    await player.play();
    for (var i = 0;
        i < 50 && player.state.duration == Duration.zero && isMounted();
        i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await player.pause();
    await player.seek(Duration.zero);
    await player.setVolume(prevVolume);
    await _yieldFrame();
  }

  /// 高音質の音声が [hqAudioWait] までに落ちていれば付ける。
  /// 間に合わなければ一体型の音声で始め、落ち次第まだ同じ曲を鳴らしていれば途中で付け替える
  /// （一瞬途切れるが、その回ずっと 96kbps で聴くよりよい）
  Future<void> _attachHqAudio(
      Player player, Future<String?>? hqAudio, LoadedMedia media) async {
    if (hqAudio == null) {
      HqAudio.log('ローダー: 高音質はオフ（設定）');
      return;
    }
    progress.step(0.95, '高音質の音声を取得中...');
    var timedOut = false;
    final path = await hqAudio.timeout(hqAudioWait, onTimeout: () {
      timedOut = true;
      return null;
    });
    if (timedOut) {
      HqAudio.log('ローダー: ${hqAudioWait.inSeconds} 秒に間に合わず、落ち次第付ける');
      unawaited(hqAudio.then((late) async {
        if (late == null) return;
        if (!isMounted() || !_stillPlaying(player, media)) {
          HqAudio.log('ローダー: 落ちたが曲が変わっていたので付けない');
          return;
        }
        await _attach(player, late);
      }));
      return;
    }
    if (path == null) {
      HqAudio.log('ローダー: 落とせなかったので一体型のまま');
      return;
    }
    if (!isMounted()) {
      HqAudio.log('ローダー: 画面を離れたので付けない');
      return;
    }
    HqAudio.log('ローダー: 取り付けへ');
    await _attach(player, path);
    await _yieldFrame();
  }

  Future<void> _attach(Player player, String path) async {
    if (await HqAudio.attach(player, path)) {
      _ref
          .read(audioQualityProvider.notifier)
          .set(player, AudioQuality.hq(HqAudio.labelFor(path)));
    }
  }

  /// [player] がまだ [media] を開いたままか（後から付けるときに曲が変わっていないか）
  static bool _stillPlaying(Player player, LoadedMedia media) {
    final medias = player.state.playlist.medias;
    return medias.isNotEmpty && medias.first.uri == media.source.uri;
  }

  /// 重い await の後に 1 フレーム描画の隙間を作る
  Future<void> _yieldFrame() =>
      Future.delayed(const Duration(milliseconds: 2));

  void _checkMounted() {
    if (!isMounted()) throw const LoadAborted();
  }
}
