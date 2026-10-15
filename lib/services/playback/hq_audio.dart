import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack, Player;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/storage/app_boxes.dart';
import '../ranged_downloader.dart';
import '../youtube_client_info.dart';

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
/// 設定「YouTube を高音質で再生」（[SettingsKeys.hqAudio]）でまとめて切れる。
class HqAudio {
  HqAudio._();

  /// 一時領域の中の置き場。ここにあるファイルは HqAudio が寿命を管理する
  /// （波形生成が使い終わっても消さない。[isManagedPath]）
  static const dirName = 'hq_audio';

  /// 残しておくファイル数。2 枚のプレイヤー + 前後の曲に戻る分
  static const keepFiles = 8;

  /// これより小さいファイルは落とし損ねとみなす
  static const minBytes = 100 * 1024;

  /// 一体型（itag 18）の音声は AAC 約 96kbps。これを超えない音声専用ストリームしか無い動画
  /// （古い投稿の 49kbps など）は付けても改悪なので、落とさず「標準」のまま鳴らす
  static const muxedAudioKbps = 96;

  /// [info] を付ける価値があるか（一体型の音声より高ビットレート）
  static bool isWorthIt(AudioOnlyStreamInfo info) =>
      isWorthItKbps(info.bitrate.kiloBitsPerSecond);

  static bool isWorthItKbps(num kbps) => kbps > muxedAudioKbps;

  /// 進行中の取得（同じ曲を再生側と波形側が同時に頼んでも 1 回で済ませる）
  static final _inFlight = <String, Future<String?>>{};

  /// 設定で有効か。box が開いていない（テスト・起動直後）なら無効扱い
  static bool get enabled {
    try {
      return AppBoxes.settings.get(SettingsKeys.hqAudio, defaultValue: true)
          as bool;
    } catch (_) {
      return false;
    }
  }

  /// [path] が HqAudio の管理下か（使い終わっても消してはいけない）
  static bool isManagedPath(String path) =>
      path.replaceAll('\\', '/').contains('/$dirName/');

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

  /// ファイル名は `<videoId>.<itag>.<kbps>k.<mp4|webm>`。
  /// 素性を画面に出すため（[labelFor]）、名前に埋めておく
  static final _fileName = RegExp(r'^([^.]+)\.(\d+)\.(\d+)k\.(mp4|webm)$');

  static String fileNameFor(String videoId, AudioOnlyStreamInfo info) =>
      '$videoId.${info.tag}.${info.bitrate.kiloBitsPerSecond.round()}k.'
      '${info.container.name}';

  /// 落とした音声の素性（「AAC 128kbps」「Opus 145kbps」）。名前が読めなければ「音声専用」
  static String labelFor(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final m = _fileName.firstMatch(name);
    if (m == null) return '音声専用';
    final codec = m.group(4) == 'mp4' ? 'AAC' : 'Opus';
    return '$codec ${m.group(3)}kbps';
  }

  /// 落としてあればそのパス（通信なし）。無ければ null
  static Future<String?> existing(String videoId) async {
    final dir = await _dir();
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.replaceAll('\\', '/').split('/').last;
        final m = _fileName.firstMatch(name);
        if (m == null || m.group(1) != videoId) continue;
        if (await _isComplete(e)) return e.path;
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
    final future = _fetch(videoId, manifest, isCancelled)
        .whenComplete(() => _inFlight.remove(videoId));
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
        // 使った順を保つ（掃除は古い順）
        try {
          await File(ready).setLastModified(DateTime.now());
        } catch (_) {}
        return ready;
      }
      final dir = await _dir();
      await _sweep(dir);

      // VISIONOS が本命（ANDROID 系の音声専用 URL は先頭 1MB で 403 になる。
      // [YouTubeClientInfo.visionOs] 参照）。念のため再生用マニフェストと androidVr も残す
      final candidates = <Future<AudioOnlyStreamInfo?> Function()>[
        () => _pickFromClient(videoId, YouTubeClientInfo.visionOs),
        if (manifest != null) () async => pickAudio(manifest.audioOnly),
        () => _pickFromClient(videoId, YoutubeApiClient.androidVr),
      ];
      for (final candidate in candidates) {
        if (isCancelled?.call() ?? false) return null;
        final info = await candidate();
        if (info == null) continue;
        if (!isWorthIt(info)) {
          debugPrint('[HqAudio] $videoId: 音声専用が '
              '${info.bitrate.kiloBitsPerSecond.round()}kbps しか無く一体型と同等以下');
          continue;
        }
        final path = await _download(dir, videoId, info, isCancelled);
        if (path != null) return path;
      }
      debugPrint('[HqAudio] $videoId: 音声専用ストリームを落とせず一体型の音声で再生');
      return null;
    } catch (e) {
      debugPrint('[HqAudio] $videoId: 取得失敗 $e');
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
      debugPrint('[HqAudio] $videoId: 取り直し失敗 $e');
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
    final state = await RangedDownloader.download(
      info.url.toString(),
      info.size.totalBytes,
      part,
      isCancelled: isCancelled,
    );
    if (state != DownloadState.ok || !await _isComplete(part)) {
      await _delete(part);
      return null;
    }
    try {
      await part.rename(file.path);
    } catch (_) {
      await _delete(part);
      return null;
    }
    debugPrint('[HqAudio] $videoId: itag ${info.tag} '
        '${info.bitrate.kiloBitsPerSecond.round()}kbps を取得');
    return file.path;
  }

  /// mpv に登録する外部トラックの名前（付いたかどうかの確認にも使う）
  static const trackTitle = 'HQ';

  /// 落とした音声を [player] の音声トラックとして付ける（ファイルを開いた後に呼ぶ）。
  /// media_kit は mpv のエラーを返さないので、トラック一覧に現れるまで待って
  /// 本当に付いたときだけ true（付かなければ一体型の音声のまま鳴る）
  static Future<bool> attach(Player player, String path) async {
    try {
      await player
          .setAudioTrack(AudioTrack.uri(path, title: trackTitle))
          .timeout(const Duration(seconds: 10));
      for (var i = 0; i < 30; i++) {
        if (isAttached(player)) return true;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      debugPrint('[HqAudio] 取り付け未確認（トラック一覧に現れない）: $path');
      return false;
    } catch (e) {
      debugPrint('[HqAudio] 取り付け失敗: $e');
      return false;
    }
  }

  /// [player] のトラック一覧に外部音声（[trackTitle]）があるか
  static bool isAttached(Player player) =>
      player.state.tracks.audio.any((t) => t.title == trackTitle);

  static Future<Directory> _dir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/$dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<bool> _isComplete(File f) async {
    try {
      return await f.exists() && await f.length() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  /// 古いものから消して [keepFiles] 件以下に保つ。落とし損ねの .part も消す
  static Future<void> _sweep(Directory dir) async {
    try {
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        if (e.path.endsWith('.part')) {
          final age = DateTime.now().difference((await e.stat()).modified);
          if (age > const Duration(hours: 1)) await _delete(e);
          continue;
        }
        files.add(e);
      }
      if (files.length < keepFiles) return;
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = (await f.stat()).modified;
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
      // これから 1 件増えるので keepFiles - 1 件だけ残す
      for (final f in files.take(files.length - (keepFiles - 1))) {
        await _delete(f);
      }
    } catch (_) {}
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
