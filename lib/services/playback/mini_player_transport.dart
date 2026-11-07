import 'dart:async';

import '../../core/audio/loudness.dart';
import '../../models/loop_item.dart';
import '../../models/playlist_track.dart';
import '../../models/video_source.dart';
import '../../providers/data_provider.dart';
import '../../providers/mini_player_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../../providers/playlist_player_provider.dart';
import '../waveform_cache.dart';
import 'playlist_transport.dart';

/// ミニプレイヤー中（再生画面を閉じた後）のプレイリスト進行を始める。
///
/// 進行の手順は再生画面と同じ [PlaylistTransportController]。画面の代わりに
/// [MiniTransportHost] を付けるだけなので、直すときは 1 か所で済む
/// （以前は MiniPlayerTransport という別実装があり、片方だけ直す事故が起きていた）。
///
/// [read] は ProviderContainer.read（画面の dispose 後も使える）。
/// [preloadedIndex] は再生画面がもう先読みして予約してある次曲の番号（読み直さない）
PlaylistTransportController startMiniTransport(ProviderReader read,
    {int? preloadedIndex}) {
  final transport = PlaylistTransportController(
    deck: EngineTransportDeck(read),
    host: MiniTransportHost(read),
    isPlaylist: true,
  )..setupCallbacks();
  if (preloadedIndex != null) transport.adoptPreloaded(preloadedIndex);
  // 画面が途中まで読んでいた分も捨てない（予約が無ければ監視が残り時間で読みに行く）
  transport.startPreloadMonitor(keepPreload: true);
  return transport;
}

/// 画面の無いときの [TransportHost]。映像・波形はプロバイダーに入れておくだけ
/// （再生画面に戻ったときに今の曲のものが出る）。字幕・1 番だけの切断点・
/// 波形の先読みは画面にしか無いので何もしない
class MiniTransportHost implements TransportHost {
  MiniTransportHost(this._read) : _session = _read(playlistEngineProvider).session;

  final ProviderReader _read;

  /// 作られたときのプレイリスト再生の番号（[PlaylistEngine.session]）
  final int _session;

  PlaylistEngine get _engine => _read(playlistEngineProvider);

  /// 別の曲・別のプレイリストが始まった（またはこのプレイリストの再生画面に戻った）ら false
  @override
  bool get mounted => _engine.session == _session;

  @override
  bool get initialLoading => false;

  @override
  void refresh() {}

  /// 画面ごとの開き直しは無い。進行役が鳴っている側に直接開く
  @override
  bool reloadCurrent() => false;

  @override
  void loadTrackRegion(PlaylistTrack track) {
    _engine.applyRegion(track);
    if (track.startMs != null) {
      try {
        _read(playerProvider).seek(Duration(milliseconds: track.startMs!));
      } catch (_) {}
    }
  }

  @override
  void showSource(PlaylistTrack track, {String? openedUri}) {
    final item = track.item;
    _read(videoSourceProvider.notifier).state = VideoSource(
      type: item.isYouTube ? VideoSourceType.youtube : VideoSourceType.local,
      uri: openedUri ?? item.uri,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );
  }

  /// 保存済みの波形があれば出しておく（無ければ空。画面に戻ったときに作る）
  @override
  void showWaveform(PlaylistTrack track) {
    final id = track.item.id;
    final data = _read(waveformDataProvider.notifier);
    data.state = null;
    _read(waveformErrorProvider.notifier).state = null;
    _read(waveformLoadingProvider.notifier).state = false;
    unawaited(WaveformCache.load(id).then((cached) {
      if (cached == null || !mounted) return;
      if (_read(miniPlayerProvider).item?.id != id) return;
      data.state = cached;
    }).catchError((_) {}));
  }

  @override
  void endLoading() {}

  /// ミニプレイヤーの表示（曲名・サムネ・番号）を切り替える
  @override
  void onTrackSwitched(PlaylistTrack track) {
    final ps = _read(playlistPlayerProvider);
    _read(miniPlayerProvider.notifier)
        .updateCurrentItem(track.item, trackIndex: ps.currentTrackIndex);
  }

  @override
  void onPreloaded(PlaylistTrack track, Object? manifest,
      {required bool Function() stillCurrent}) {}

  @override
  double normalizedVolume(LoopItem item) {
    if (!_read(volumeNormProvider)) return 100.0;
    final latest = _read(loopItemsProvider.notifier).byId(item.id) ?? item;
    return Loudness.volumeFor(latest.loudnessDb);
  }
}
