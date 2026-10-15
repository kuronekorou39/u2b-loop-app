import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack, Player;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/storage/app_boxes.dart';
import '../ranged_downloader.dart';
import '../youtube_client_info.dart';
import 'media_cache.dart';

/// YouTube の音声を高音質（音声専用ストリーム）で鳴らすための取得と取り付け。
///
/// YouTube が「映像+音声一体」で配るのは 360p（音声 AAC 約 96kbps）だけで、
/// 本家アプリが使う音声専用ストリーム（AAC 128kbps / Opus 約 140kbps）より
/// 聞いて分かるほど劣る。そこで音声専用ストリームを一時ファイルに落とし、
/// mpv の外部音声トラックとして映像（一体型）に重ねる。同じエンコードの
/// タイムラインなのでずれは蓄積しない。
///
/// 音声専用ストリームは PO トークン無しだと途中の Range で 403 を返すことがあるので、
/// ストリーミングせず**先に全部落として**から使う。落とせなければ何もせず、
/// 今まで通り一体型の音声で鳴る（途中で無音になる失敗はしない）。
/// 落とした音声は波形生成にも使い回す（従来は波形のために一体型を別途落としていた）。
///
/// 置き場は自動キャッシュ（[MediaCache]）と共通で、上限を超えたら古い順に消える。
/// 長い曲（[MediaCache.maxDuration] 超）の音声は `.long` 印を付け、最新の数件だけ残す。
///
/// 設定「YouTube を高音質で再生」（[SettingsKeys.hqAudio]）でまとめて切れる。
class HqAudio {
  HqAudio._();


  /// 一体型（itag 18）の音声は AAC 約 96kbps。これを超えない音声専用ストリームしか無い動画
  /// （古い投稿の 49kbps など）は付けても改悪なので、落とさず「標準」のまま鳴らす
  static const muxedAudioKbps = 96;

  /// [info] を付ける価値があるか（一体型の音声より高ビットレート）
  static bool isWorthIt(AudioOnlyStreamInfo info) =>
      isWorthItKbps(info.bitrate.kiloBitsPerSecond);

  static bool isWorthItKbps(num kbps) => kbps > muxedAudioKbps;

  /// 進行中の取得（同じ曲を再生側と波形側が同時に頼んでも 1 回で済ませる）
  static final _inFlight = <String, Future<String?>>{};

  /// 直近のログ（新しいものが後ろ）。端末では logcat を読めないので、
  /// 設定「高音質のログ」で見せる。[logVersion] が増えたら画面を更新する
  static final List<String> recentLog = [];
  static final ValueNotifier<int> logVersion = ValueNotifier(0);
  static const _maxLogLines = 80;

  /// 呼び出し側（ローダー・エンジン）も判断をここに残す
  static void log(String message) => _log(message);

  static void _log(String message) {
    debugPrint('[HqAudio] $message');
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    recentLog.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $message');
    if (recentLog.length > _maxLogLines) recentLog.removeAt(0);
    logVersion.value++;
  }

  /// 設定で有効か。box が開いていない（テスト・起動直後）なら無効扱い
  static bool get enabled {
    try {
      return AppBoxes.settings.get(SettingsKeys.hqAudio, defaultValue: true)
          as bool;
    } catch (_) {
      return false;
    }
  }

  /// [path] が自動キャッシュの管理下か（使い終わっても消してはいけない）
  static bool isManagedPath(String path) => MediaCache.isManagedPath(path);

  /// 音声専用ストリームから使うものを選ぶ。
  /// 波形生成（MediaExtractor / MP4 パーサ）と同じ mp4 コンテナを優先し、
  /// その中で最高ビットレート。mp4 が無ければ webm（Opus）の最高ビットレート
  static AudioOnlyStreamInfo? pickAudio(Iterable<AudioOnlyStreamInfo> streams) {
    final list = streams.toList();
    final i = pickIndex([
      for (final s in list)
        (mp4: s.container == StreamContainer.mp4, bps: s.bitrate.bitsPerSecond),
    ]);
    return i < 0 ? null : list[i];
  }

  /// [pickAudio] の選び方（純粋な計算。テスト用に分けてある）。候補が無ければ -1
  static int pickIndex(List<({bool mp4, int bps})> candidates) {
    var best = -1;
    for (var i = 0; i < candidates.length; i++) {
      if (best < 0) {
        best = i;
        continue;
      }
      final c = candidates[i];
      final b = candidates[best];
      if (c.mp4 != b.mp4) {
        if (c.mp4) best = i;
        continue;
      }
      if (c.bps > b.bps) best = i;
    }
    return best;
  }

  /// ファイル名は `<videoId>.<itag>.<kbps>k[.long].<mp4|webm>`。
  /// 素性を画面に出すため（[labelFor]）、名前に埋めておく。`.long` は長い曲の印（[MediaCache]）
  static final _fileName =
      RegExp(r'^([^.]+)\.(\d+)\.(\d+)k(\.long)?\.(mp4|webm)$');

  static String fileNameFor(String videoId, AudioOnlyStreamInfo info) {
    final long = MediaCache.isTooLong(MediaCache.estimateDuration(
        info.size.totalBytes, info.bitrate.bitsPerSecond));
    return fileNameForParts(videoId, info.tag,
        info.bitrate.kiloBitsPerSecond.round(), info.container.name,
        long: long);
  }

  static String fileNameForParts(String videoId, int itag, int kbps, String ext,
          {bool long = false}) =>
      '$videoId.$itag.${kbps}k${long ? '.long' : ''}.$ext';

  /// 落とした音声の素性（「AAC 128kbps」「Opus 145kbps」）。名前が読めなければ「音声専用」
  static String labelFor(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final m = _fileName.firstMatch(name);
    if (m == null) return '音声専用';
    final codec = m.group(5) == 'mp4' ? 'AAC' : 'Opus';
    return '$codec ${m.group(3)}kbps';
  }

  /// 落としてあればそのパス（通信なし）。無ければ null
  static Future<String?> existing(String videoId) async {
    final dir = await MediaCache.dir();
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.replaceAll('\\', '/').split('/').last;
        final m = _fileName.firstMatch(name);
        if (m == null || m.group(1) != videoId) continue;
        if (await MediaCache.isComplete(e)) return e.path;
      }
    } catch (_) {}
    return null;
  }

  /// [videoId] の音声専用ストリームを落としてパスを返す。
  /// 落としてあれば即返す。[manifest]（再生用に取得済みのもの）があればまずそこから選び、
  /// 落とせなければ androidVr クライアントで取り直して再挑戦する。全部だめなら null。
  /// [isCancelled] が true を返したら途中で止める（曲を素早く切り替えた時）
  static Future<String?> fetch(
    String videoId, {
    StreamManifest? manifest,
    bool Function()? isCancelled,
  }) {
    final running = _inFlight[videoId];
    if (running != null) return running;
    // whenComplete のコールバックが Future を返すとそれを待つ仕様なので、
    // `() => _inFlight.remove(videoId)` と書くと remove が返す「自分自身」を待って
    // 永遠に完了しない（v1.91.0〜v1.91.6 で取り付けに進めなかった原因）。式ではなく文にする
    final future = _fetch(videoId, manifest, isCancelled).whenComplete(() {
      _inFlight.remove(videoId);
    });
    _inFlight[videoId] = future;
    return future;
  }

  static Future<String?> _fetch(
    String videoId,
    StreamManifest? manifest,
    bool Function()? isCancelled,
  ) async {
    try {
      final ready = await existing(videoId);
      if (ready != null) {
        _log('$videoId: 落とし済み ${labelFor(ready)}');
        await MediaCache.touch(ready);
        return ready;
      }
      _log('$videoId: 取得開始');
      final dir = await MediaCache.dir();

      // VISIONOS が本命（ANDROID 系の音声専用 URL は先頭 1MB で 403 になる。
      // [YouTubeClientInfo.visionOs] 参照）。念のため再生用マニフェストと androidVr も残す
      final candidates = <(String, Future<AudioOnlyStreamInfo?> Function())>[
        ('VISIONOS', () => _pickFromClient(videoId, YouTubeClientInfo.visionOs)),
        if (manifest != null)
          ('再生用マニフェスト', () async => pickAudio(manifest.audioOnly)),
        ('ANDROID_VR', () => _pickFromClient(videoId, YoutubeApiClient.androidVr)),
      ];
      for (final (name, candidate) in candidates) {
        if (isCancelled?.call() ?? false) {
          _log('$videoId: 曲が変わったので中止');
          return null;
        }
        final info = await candidate();
        if (info == null) {
          _log('$videoId: $name から音声専用を取れず');
          continue;
        }
        _log('$videoId: $name → itag ${info.tag} '
            '${info.bitrate.kiloBitsPerSecond.round()}kbps '
            '${info.size.totalMegaBytes.toStringAsFixed(1)}MB');
        if (!isWorthIt(info)) {
          _log('$videoId: 一体型（${muxedAudioKbps}kbps）と同等以下なので付けない');
          continue;
        }
        final path = await _download(dir, videoId, info, isCancelled);
        if (path != null) return path;
      }
      _log('$videoId: 落とせず一体型の音声で再生');
      return null;
    } catch (e) {
      _log('$videoId: 取得失敗 $e');
      return null;
    }
  }

  static Future<AudioOnlyStreamInfo?> _pickFromClient(
      String videoId, YoutubeApiClient client) async {
    final yt = YoutubeExplode();
    try {
      final m = await yt.videos.streamsClient
          .getManifest(videoId, ytClients: [client])
          .timeout(const Duration(seconds: 30));
      return pickAudio(m.audioOnly);
    } catch (e) {
      _log('$videoId: マニフェスト取得失敗 ${e.toString().split('\n').first}');
      return null;
    } finally {
      yt.close();
    }
  }

  static Future<String?> _download(
    Directory dir,
    String videoId,
    AudioOnlyStreamInfo info,
    bool Function()? isCancelled,
  ) async {
    final file = File('${dir.path}/${fileNameFor(videoId, info)}');
    final part = File('${file.path}.part');
    final sw = Stopwatch()..start();
    final state = await RangedDownloader.download(
      info.url.toString(),
      info.size.totalBytes,
      part,
      isCancelled: isCancelled,
      onFailed: (reason) => _log('$videoId: DL 失敗 $reason'),
    );
    if (state != DownloadState.ok || !await MediaCache.isComplete(part)) {
      if (state == DownloadState.ok) _log('$videoId: DL したが小さすぎる');
      await _delete(part);
      return null;
    }
    try {
      await part.rename(file.path);
    } catch (e) {
      _log('$videoId: ファイル名の確定に失敗 $e');
      await _delete(part);
      return null;
    }
    _log('$videoId: itag ${info.tag} ${info.bitrate.kiloBitsPerSecond.round()}kbps '
        'を取得（${sw.elapsed.inMilliseconds}ms）');
    unawaited(MediaCache.enforceLimit());
    return file.path;
  }

  /// mpv に登録する外部トラックの名前（付いたかどうかの確認にも使う）
  static const trackTitle = 'HQ';

  /// 落とした音声を [player] の音声トラックとして付ける（ファイルを開いた後に呼ぶ）。
  /// media_kit は mpv のエラーを返さないので、トラック一覧に現れるまで待って
  /// 本当に付いたときだけ true（付かなければ一体型の音声のまま鳴る）
  static Future<bool> attach(Player player, String path) async {
    try {
      int size = -1;
      try {
        size = await File(path).length();
      } catch (_) {}
      _log('取り付け開始 ${labelFor(path)} ${size ~/ 1024}KB '
          '（今のトラック: ${_audioTrackSummary(player)}）');
      await player
          .setAudioTrack(AudioTrack.uri(path, title: trackTitle))
          .timeout(const Duration(seconds: 10));
      for (var i = 0; i < 30; i++) {
        if (isAttached(player)) {
          _log('取り付け完了 ${labelFor(path)}');
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _log('取り付け未確認（トラック一覧: ${_audioTrackSummary(player)}）');
      return false;
    } catch (e) {
      _log('取り付け失敗 $e');
      return false;
    }
  }

  static String _audioTrackSummary(Player player) {
    final list = player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .map((t) => '${t.id}:${t.title ?? '-'}')
        .join(', ');
    return list.isEmpty ? 'なし' : list;
  }

  /// [player] のトラック一覧に外部音声（[trackTitle]）があるか
  static bool isAttached(Player player) =>
      player.state.tracks.audio.any((t) => t.title == trackTitle);

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
