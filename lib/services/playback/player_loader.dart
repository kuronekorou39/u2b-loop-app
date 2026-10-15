import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../models/loop_item.dart';
import '../../models/video_source.dart';
import '../../providers/player_provider.dart';
import '../cache_service.dart';
import '../youtube_service.dart';
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
/// 3. videoSourceProvider に流す
/// 4. duration が取れるまで無音で短く再生してメタデータを確定させる
///    （0 のままだとループ監視も終端検知も働かない）
/// 5. **毎回**速度を設定する（プレイヤーを使い回すので、前の曲の速度が残る）
///
/// プレイリストの遷移（プリロード側）は PlaylistEngine.prepare が同じことをする。
/// 直す時は両方を見ること
class PlayerLoader {
  PlayerLoader(this._ref, {required this.progress, required this.isMounted});

  final WidgetRef _ref;
  final LoadProgress progress;
  final bool Function() isMounted;

  static const openTimeout = Duration(seconds: 60);

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
      final offline = CacheService.offlineVideoPath(item);
      final LoadedMedia media;
      if (offline != null) {
        // オフライン保存済み: 通信なしでローカルファイルを再生
        await progress.step(0.40, 'オフラインキャッシュを読み込み中...');
        media = LoadedMedia(source: sourceFor(item, offlinePath: offline));
        await progress.step(0.70, 'プレーヤーを準備中...');
        await player.open(Media(offline), play: false);
      } else if (item.isYouTube) {
        await progress.step(0.15, 'ストリーム情報を解析中...');
        final manifest = await _ref
            .read(youtubeServiceProvider)
            .getManifestWithFallback(item.videoId!);
        await _yieldFrame();
        _checkMounted();
        media = LoadedMedia(
          source: sourceFor(item,
              streamUrl: YouTubeService.pickStreamUrl(manifest)),
          manifest: manifest,
        );
        await progress.step(0.50, 'プレーヤーを準備中...');
        await player
            .open(Media(media.source.uri), play: false)
            .timeout(openTimeout);
      } else {
        await progress.step(0.30, 'ファイルを読み込み中...');
        media = LoadedMedia(source: sourceFor(item));
        await progress.step(0.65, 'プレーヤーを準備中...');
        await player.open(Media(item.uri), play: false);
      }
      onOpened?.call(media);
      await _yieldFrame();
      _checkMounted();
      _ref.read(videoSourceProvider.notifier).state = media.source;

      await _waitForMetadata(player);
      _checkMounted();
      await player.setRate(item.speed);
      return media;
    } catch (_) {
      progress.end();
      rethrow;
    }
  }

  /// 最後の段階「読み込み完了！」を少し見せてから Tip を止める。
  /// 呼び出し側はこの後で画面を切り替える
  Future<void> finish() async {
    _checkMounted();
    await progress.step(1.0, '読み込み完了！');
    await Future.delayed(const Duration(milliseconds: 300));
    _checkMounted();
    progress.end();
  }

  Future<void> _waitForMetadata(Player player) async {
    if (player.state.duration != Duration.zero) return;
    await progress.step(0.90, 'メタデータを取得中...');
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

  /// 重い await の後に 1 フレーム描画の隙間を作る
  Future<void> _yieldFrame() =>
      Future.delayed(const Duration(milliseconds: 2));

  void _checkMounted() {
    if (!isMounted()) throw const LoadAborted();
  }
}
