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
import '../waveform_cache.dart';
import '../waveform_service.dart';
import 'hq_audio.dart';

/// 再生画面で波形を用意する手順。
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

  /// 音量正規化がオンで、曲の大きさがまだ無い（保存済みの波形からは分からない）
  bool _needLoudness(LoopItem item) =>
      _ref.read(volumeNormProvider) && item.loudnessDb == null;

  /// 音声を先読みしてから [generate] を呼ぶ（待たない）。
  /// 保存した波形は先読みを待たずにすぐ出す。波形が保存済みで解析も不要なら DL せずにすぐ [generate]
  void prefetchThenGenerate(
      LoopItem item, StreamManifest manifest, VoidCallback generate) {
    // 長い動画は波形を作らない（音声も落とさない）
    if (WaveformService.tooLongForWaveform(
        durationMs: item.durationMs, manifest: manifest)) {
      return;
    }
    () async {
      final cached = await _showCached(item);
      var skip = await WaveformService.canSkipAudioFetch(item,
          needLoudness: _needLoudness(item));
      // この起動中にもう試した曲は、保存した波形があれば音声を落とし直さない
      if (cached && WaveformService.decodeTried(item.id)) skip = true;
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
    }();
  }

  /// 保存した波形があれば、まだ何も出ていないうちに出す（デコードを待たない）。出せたら true
  Future<bool> _showCached(LoopItem item) async {
    final cached = await WaveformCache.load(item.id);
    if (cached == null || cached.isEmpty || !isMounted()) return false;
    final data = _ref.read(waveformDataProvider.notifier);
    if (data.state == null) {
      data.state = cached;
      _ref.read(waveformErrorProvider.notifier).state = null;
      _ref.read(waveformLoadingProvider.notifier).state = false;
    }
    return true;
  }

  /// 読み込み完了時に波形を作るか: ローカルは即、YouTube は先読みが済んでいれば
  /// （済んでいなければ [prefetchThenGenerate] が後で呼ぶ）
  /// 自動キャッシュ・オフライン保存から開いた YouTube（URI が端末内のファイル）も即
  bool shouldGenerateNow(VideoSource source) =>
      source.type == VideoSourceType.local ||
      source.uri.startsWith('/') ||
      _prefetchedAudioPath != null;

  /// 何回目の [generate] か。古い呼び出しが後から終わっても表示を上書きしないように
  int _generation = 0;

  /// 波形を作って provider に流す。戻り値は成功した波形（失敗・空・中止は null）。
  /// 保存した波形があれば先に出し、解析・帯域・大きさのためのデコードはその裏で
  /// （読込中にしない。失敗しても保存した波形のまま）
  Future<List<double>?> generate(VideoSource source, LoopItem item) async {
    final gen = ++_generation;
    bool current() => isMounted() && gen == _generation;
    final data = _ref.read(waveformDataProvider.notifier);
    final error = _ref.read(waveformErrorProvider.notifier);
    final loading = _ref.read(waveformLoadingProvider.notifier);
    error.state = null;
    // 長い動画は波形を作らない（細いシークバーだけ。読込中もエラーも出さない）
    if (WaveformService.tooLongForWaveform(
        durationMs: item.durationMs,
        playerDuration: _ref.read(playerProvider).state.duration)) {
      data.state = null;
      loading.state = false;
      return null;
    }
    final saved = await WaveformCache.load(item.id);
    if (!current()) return null;
    final cached = saved != null && saved.isNotEmpty ? saved : null;
    data.state = cached;
    loading.state = cached == null;
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
        // 曲の大きさ（音量正規化用）はデコードしたときに毎回測って残す
        onLoudness: (db) =>
            _ref.read(loopItemsProvider.notifier).saveLoudness(item.id, db),
        needLoudness: _needLoudness(item),
        cacheKey: item.id,
      );
      if (!current()) return null;
      if (waveform == null || waveform.isEmpty) {
        if (cached == null) error.state = failedMessage;
        return cached;
      }
      data.state = waveform;
      return waveform;
    } on WaveformCancelled {
      // 新しい波形を頼んだので中止された（表示はそちらが決める）
      return null;
    } catch (e) {
      if (current() && cached == null) error.state = AppErrors.describe(e);
      return current() ? cached : null;
    } finally {
      if (current()) loading.state = false;
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
