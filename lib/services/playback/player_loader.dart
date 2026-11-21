import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../models/loop_item.dart';
import '../../models/video_source.dart';
import '../../providers/player_provider.dart';
import 'load_progress.dart';
import 'media_opener.dart';

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

/// 再生画面で曲を開く手順。
///
/// 開く手順そのもの（オフライン → 自動キャッシュ → YouTube → ローカル、メタデータ待ち、
/// 高音質の音声、速度、音声フィルタ）は [MediaOpener]（プレイリストの PlaylistEngine.prepare と
/// 共通）。ここは再生画面の分だけ:
/// - 進捗の表示を進める
/// - 鳴っている側のプレイヤーで開く。YouTube は [openTimeout] で打ち切る
/// - 画面を離れたら [LoadAborted] を投げる
/// - 最後に videoSourceProvider に流す（これを見てコントローラーが押せるようになる）
class PlayerLoader {
  PlayerLoader(this._ref, {required this.progress, required this.isMounted});

  final WidgetRef _ref;
  final LoadProgress progress;
  final bool Function() isMounted;

  static const openTimeout = Duration(seconds: 60);

  /// 高音質の音声（数 MB）を待つ上限。開く+メタデータ待ちと並行して落ちているので、
  /// 普通の回線ならここで待つのは残りだけ
  static const hqAudioWait = Duration(seconds: 8);

  /// duration が取れるまで待つ上限
  static const metadataWait = Duration(seconds: 5);

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

  /// [MediaOpener] で開いたものを、画面が使うソースにする
  static LoadedMedia mediaOf(LoopItem item, OpenedMedia opened) =>
      LoadedMedia(
        source: switch (opened.origin) {
          MediaOrigin.offline => sourceFor(item, offlinePath: opened.uri),
          MediaOrigin.youtube => sourceFor(item, streamUrl: opened.uri),
          MediaOrigin.local => sourceFor(item),
        },
        manifest: opened.manifest,
      );

  /// [item] を開いて再生できる状態にする（まだ再生はしない）。
  /// [onOpened] は `player.open` の直後（メタデータ待ちの前）に呼ぶ。
  /// 波形の音声先読みなど、待たせたくない裏の仕事を始めるのに使う
  Future<LoadedMedia> load(LoopItem item,
      {void Function(LoadedMedia media)? onOpened}) async {
    try {
      final opened = await MediaOpener(
        _ref.read,
        isCancelled: () => !isMounted(),
        onStep: progress.step,
        logTag: 'ローダー',
      ).open(
        _ref.read(playerProvider),
        item,
        startAt: () => Duration.zero,
        metadataWait: metadataWait,
        hqAudioWait: hqAudioWait,
        streamOpenTimeout: openTimeout,
        onOpened: onOpened == null ? null : (m) => onOpened(mediaOf(item, m)),
      );
      if (opened == null) throw const LoadAborted();
      final media = mediaOf(item, opened);
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
    if (!isMounted()) throw const LoadAborted();
    progress.step(1.0, '読み込み完了');
    progress.end();
  }
}
