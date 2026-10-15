import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/app_errors.dart';
import '../../models/loop_item.dart';
import '../../models/video_source.dart';
import '../../providers/data_provider.dart';
import '../../providers/player_provider.dart';
import '../audio_analysis_service.dart';
import '../waveform_service.dart';
import 'hq_audio.dart';

/// 再生画面と AB 設定画面で同じ手順で波形を用意する。
///
/// - YouTube をネットから開いたときは [prefetchThenGenerate] で音声を裏で先読みし、
///   済んだら生成（再生のロードを待たせない）。波形が保存済みで解析も不要なら DL しない
/// - ローカルは読み込み完了時にすぐ生成（[shouldGenerateNow]）
/// - [generate] が waveformData / Loading / Error の provider に流す。
///   画面ごとの後処理（キャッシュ・切断点・音量正規化）は戻り値で
class WaveformLoader {
  WaveformLoader(this._ref, {required this.isMounted});

  final WidgetRef _ref;
  final bool Function() isMounted;

  /// 先読みした音声の一時ファイル。[generate] が使って消す
  String? _prefetchedAudioPath;

  static const failedMessage = '波形取得失敗';

  /// 音声を先読みしてから [generate] を呼ぶ（待たない）。
  /// 波形が保存済み（かつ解析不要）なら DL せずにすぐ [generate]
  void prefetchThenGenerate(
      LoopItem item, StreamManifest manifest, VoidCallback generate) {
    WaveformService.canSkipAudioFetch(item).then((skip) async {
      if (!isMounted()) return;
      if (!skip) {
        final videoId = item.videoId;
        if (videoId == null) return;
        final path = await WaveformService().prefetchAudio(
            manifest, _ref.read(youtubeServiceProvider),
            videoId: videoId);
        if (path == null || !isMounted()) return;
        _prefetchedAudioPath = path;
      }
      generate();
    });
  }

  /// 読み込み完了時に波形を作るか: ローカルは即、YouTube は先読みが済んでいれば
  /// （済んでいなければ [prefetchThenGenerate] が後で呼ぶ）
  bool shouldGenerateNow(VideoSource source) =>
      source.type == VideoSourceType.local || _prefetchedAudioPath != null;

  /// 波形を作って provider に流す。戻り値は成功した波形（失敗・空は null）
  Future<List<double>?> generate(VideoSource source, LoopItem item) async {
    final data = _ref.read(waveformDataProvider.notifier);
    final error = _ref.read(waveformErrorProvider.notifier);
    final loading = _ref.read(waveformLoadingProvider.notifier);
    data.state = null;
    error.state = null;
    loading.state = true;
    try {
      final service = WaveformService();
      await service.cancel();

      if (source.type != VideoSourceType.local && source.videoId == null) {
        return null;
      }
      // 先読み済みの音声があれば DL を省略する
      final prefetched = _prefetchedAudioPath;
      _prefetchedAudioPath = null;
      final waveform = await service.generateForVideoSource(
        source,
        _ref.read(youtubeServiceProvider),
        cachedAudioPath: prefetched,
        // 未解析ならテンポ/キー解析をデコードに相乗りさせる（長すぎる曲は除く）
        onPcm: AudioAnalysisService.sinkFor(
            _ref.read(loopItemsProvider.notifier), item,
            duration: _ref.read(playerProvider).state.duration),
        cacheKey: item.id,
      );
      if (!isMounted()) return null;
      if (waveform == null || waveform.isEmpty) {
        error.state = failedMessage;
        return null;
      }
      data.state = waveform;
      return waveform;
    } catch (e) {
      if (isMounted()) error.state = AppErrors.describe(e);
      return null;
    } finally {
      if (isMounted()) loading.state = false;
    }
  }

  /// 画面を離れるとき: 先読みしたまま使わなかった一時ファイルを消す
  /// （高音質の音声は再生にも使うので HqAudio に任せる）
  void dispose() {
    final path = _prefetchedAudioPath;
    _prefetchedAudioPath = null;
    if (path != null && !HqAudio.isManagedPath(path)) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
}
