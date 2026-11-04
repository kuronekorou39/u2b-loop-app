import 'dart:math';

import 'package:hive/hive.dart';
import '../core/audio/beat_grid.dart';
import '../core/audio/key_sections.dart';
import '../core/audio/musical_key.dart';
import '../core/audio/tempo_sections.dart';
import '../core/utils/time_utils.dart';
import 'loop_region.dart';

/// [LoopItem.sourceType] に入る値。
/// Hive にはこの文字列のまま保存されているので、値を変えると既存データが読めなくなる。
class SourceTypes {
  SourceTypes._();
  static const youtube = 'youtube';
  static const local = 'local';
}

class LoopItem {
  String id;
  String title;
  String uri;

  /// [SourceTypes] のいずれか。比較には [isYouTube] / [isLocal] を使うこと
  String sourceType;
  String? videoId;
  String? thumbnailUrl;
  String? thumbnailPath;
  int pointAMs;
  int pointBMs;
  double speed;
  String? memo;
  DateTime createdAt;
  DateTime updatedAt;

  /// null=取得完了, 'fetching'=取得中, 'error:...'=エラー
  String? fetchStatus;

  /// タグID一覧
  List<String> tagIds;

  /// 元のYouTube URL（コピー・アクセス用）
  String? youtubeUrl;

  /// 複数AB区間
  List<LoopRegion> regions;

  /// 再生回数
  int playCount;

  /// 未カウント分の累積再生時間（ミリ秒）
  int accumulatedPlayMs;

  /// 字幕の有無（null=未チェック, true=あり, false=なし）
  bool? hasSubtitles;

  /// オフライン再生用にダウンロード保存した動画ファイルのパス（null=未キャッシュ）
  String? cachedVideoPath;

  /// オフライン再生用に保存した字幕ファイル(SRT)のパス
  String? cachedSubtitlePath;

  /// キャッシュした動画の画質ラベル（例: '720p'。表示用）
  String? cachedResolution;

  /// キャッシュした動画ファイルのサイズ（バイト。容量表示用）
  int? cachedSizeBytes;

  /// キャッシュした時刻（ミリ秒。LRU削除用）
  int? cachedAt;

  /// 検出したテンポ（手動補正後の値。null=未解析または検出失敗）
  double? bpm;

  /// 検出したキー。'Gmin' / 'A#maj' 形式（MusicalKey.allKeys のいずれか）
  String? musicalKey;

  /// テンポ/キーを解析した時刻（ミリ秒。null=未解析。再解析のスキップ判定用）
  int? analyzedAt;

  /// 解析結果の形式の版（[currentAnalysisVersion]）。これより古い解析結果は解析し直す。
  /// null = 版を持たない旧い解析結果。手動補正では触らない（解析の時刻で判定すると、
  /// 境目の前後に旧いアプリで解析した曲を取りこぼす）
  int? analysisVersion;

  /// 解析に入れるものを増やしたら上げる（1: 無音、2: 拍の格子、3: 格子の信頼度、4: 小節頭、
  /// 5: 曲の範囲、6: テンポの区切り、7: キーの検出を CQT に直して転調も）
  static const currentAnalysisVersion = 7;

  /// 曲頭の無音（ミリ秒）。クロスフェードで無音同士を重ねないために使う。
  /// null = 未計測（v1.72 以前の解析結果。再解析で埋まる）
  int? leadingSilenceMs;

  /// 曲末の無音（ミリ秒）。null = 未計測、または曲が長すぎて曲末まで解析していない
  int? trailingSilenceMs;

  /// 曲が始まるまでの曲でない部分（ミリ秒。トーク・OP の語りなど、拍の無い部分）。
  /// null = 未計測（v1.119 以前の解析）
  int? musicHeadMs;

  /// 曲が終わってからの曲でない部分（ミリ秒。ED の語りなど）。
  /// null = 未計測、または曲末まで解析していない
  int? musicTailMs;

  /// 曲ではないと判定した（拍のはっきりした部分がほとんど無い）。BPM・キーは出さない
  bool? notMusic;

  /// テンポの区切り（[TempoSection.flatten] の形）。テンポが変わる曲だけ。null = 一定か未計測。
  /// [bpm] は一番長い区切りのテンポ
  List<double>? tempoSectionData;

  List<TempoSection> get tempoSections => tempoSectionData == null
      ? const []
      : TempoSection.unflatten(tempoSectionData!);

  /// キーの区切り（'開始ms:キー' の並び）。転調する曲だけ。null = 一定か未計測。
  /// [musicalKey] は一番長い区切りのキー
  List<String>? keySectionData;

  List<KeySection> get keySections => [
        for (final s in keySectionData ?? const <String>[])
          if (s.indexOf(':') case final i when i > 0)
            KeySection(int.tryParse(s.substring(0, i)) ?? 0, s.substring(i + 1)),
      ];

  static List<String> flattenKeySections(List<KeySection> sections) =>
      [for (final s in sections) '${s.startMs}:${s.key}'];

  /// 曲の始まりのキー（DJ で次の曲として入るときに比べる）
  String? get startKey {
    final s = keySections;
    return s.length >= 2 ? s.first.key : musicalKey;
  }

  /// 曲の終わりのキー（DJ で前の曲として出るときに比べる）
  String? get endKey {
    final s = keySections;
    return s.length >= 2 ? s.last.key : musicalKey;
  }

  /// 一覧のキーの表記。一定なら「Gmin」、転調するなら「A#min → Bmin」（3 つまで並べ、
  /// それより多ければ最初 → … → 最後）
  String? get keyLabel {
    final s = keySections;
    if (s.length < 2) return musicalKey;
    final keys = [for (final x in s) x.key];
    return keys.length <= 3
        ? keys.join(' → ')
        : '${keys.first} → … → ${keys.last}';
  }

  /// キーの区切りの並び（「0:00 A#min → 2:36 Bmin」）。一定なら null
  String? get keySectionsLabel {
    final s = keySections;
    if (s.length < 2) return null;
    return s
        .map((x) => '${TimeUtils.formatShortMs(x.startMs)} ${MusicalKey.display(x.key) ?? x.key}')
        .join(' → ');
  }

  /// テンポの区切りごとの拍の格子（[tempoSections] と同じ並び、1 つにつき
  /// [bpm, offsetMs, confidence, downbeatMs, downbeatConfidence] の 5 つ。小節頭が無ければ −1、
  /// 格子が無ければ bpm が 0）。null = テンポが一定か未計測
  List<double>? sectionGridData;

  static const _gridFields = 5;

  static List<double> flattenGrids(List<BeatGrid?> grids) => [
        for (final g in grids)
          ...g == null
              ? const [0.0, 0.0, 0.0, -1.0, -1.0]
              : [g.bpm, g.offsetMs, g.confidence, g.downbeatMs ?? -1, g.downbeatConfidence ?? -1],
      ];

  List<BeatGrid?> get sectionGrids {
    final d = sectionGridData;
    if (d == null) return const [];
    return [
      for (var i = 0; i + _gridFields <= d.length; i += _gridFields)
        d[i] <= 0
            ? null
            : BeatGrid(
                bpm: d[i],
                offsetMs: d[i + 1],
                confidence: d[i + 2],
                downbeatMs: d[i + 3] < 0 ? null : d[i + 3],
                downbeatConfidence: d[i + 4] < 0 ? null : d[i + 4],
              ),
    ];
  }

  /// 一番長いテンポの区切りの番号（その区切りの格子は [beatGrid]。ジョグ・フェーダーで直した値）。
  /// 区切りが無ければ null
  int? get mainTempoSectionIndex {
    final s = tempoSections;
    if (s.length < 2) return null;
    final end = durationMs == null ? null : durationMs! - (musicTailMs ?? 0);
    var best = 0, bestLen = -1;
    for (var i = 0; i < s.length; i++) {
      final next = i + 1 < s.length ? s[i + 1].startMs : (end ?? s[i].startMs);
      final len = next - s[i].startMs;
      if (len > bestLen) {
        bestLen = len;
        best = i;
      }
    }
    return best;
  }

  /// テンポの区切りの並び（「0:00 96 → 1:21 148」）。一定なら null
  String? get tempoSectionsLabel {
    final s = tempoSections;
    if (s.length < 2) return null;
    return s
        .map((x) => '${TimeUtils.formatShortMs(x.startMs)} ${x.bpm.round()}')
        .join(' → ');
  }

  /// 曲頭で飛ばしてよい長さ: 無音と、曲でない部分の長い方
  int get introSkipMs => max(leadingSilenceMs ?? 0, musicHeadMs ?? 0);

  /// 曲末で飛ばしてよい長さ: 無音と、曲でない部分の長い方。どちらも未計測なら null
  int? get outroSkipMs => trailingSilenceMs == null && musicTailMs == null
      ? null
      : max(trailingSilenceMs ?? 0, musicTailMs ?? 0);

  /// ミックスイン点（ミリ秒）: 曲頭側で音量がぐっと上がる点（ドロップ）。
  /// クロスフェードで入るとき、ここが切り替わりに来るよう開始位置をずらす。
  /// 波形から求める（MixPointDetector）。null = 未計測または無し
  int? mixInMs;

  /// ミックスアウト点（ミリ秒）: 曲末側で音量が落ち込む点（アウトロの始まり）。
  /// 出ていく曲はここで切る。null = 未計測または無し
  int? mixOutMs;

  /// 拍の格子: 最初の拍の位置（ミリ秒）と精密な BPM。拍合わせに使う。
  /// [bpm] は表示・手動補正用の 0.1 刻みで、こちらは解析結果そのまま。
  /// null = 未計測（v1.85 以前の解析）または BPM が取れなかった
  double? beatOffsetMs;
  double? beatBpm;

  /// 拍の格子の当てはまり（0〜1）。null = 未計測（v1.94 以前の解析）→ 信用する扱い
  double? beatConfidence;

  /// 小節頭（1 拍目の拍の頭、ミリ秒）とその確かさ（0〜1）。null = 未計測（v1.106 以前の解析）
  double? downbeatMs;
  double? downbeatConfidence;

  /// 音量の流れ（波形から。ピーク比 dB。EnergyProfile）。おまかせがつなぎ方を選ぶのに使う。
  /// ミックス点と同じく再生中に波形から求めて残す。null = 未計測
  double? headDb;
  double? tailDb;
  double? endFadeDb;
  double? dropDb;

  /// 音量の流れそのもの（曲頭から [EnergyProfile.curveStepMs] ごとの平均 dB、ピーク比）。
  /// 次曲の入り口を前曲の出口に合わせて選ぶ（EntryPlanner）のに使う。null = 未計測
  List<double>? energyDb;

  /// 曲全体の RMS（dBFS）。音量正規化が曲の大きさを揃えるのに使う（Loudness）。
  /// 波形を作るときにデコードした PCM から測る。null = 未計測
  double? loudnessDb;

  /// 「1番だけ」で使う範囲（ミリ秒）。1番モード中に AB を手で直したときに残す。
  /// null なら毎回波形から自動で探す（VerseDetector）。区間（regions）とは別で、
  /// 1番モードでないふつうの再生には影響しない
  int? firstVerseAMs;
  int? firstVerseBMs;

  /// 手で直した 1 番の範囲があるか
  bool get hasFirstVerse => firstVerseAMs != null && firstVerseBMs != null;

  /// 曲の長さ（ミリ秒）。再生したとき、または解析の前に YouTube へ問い合わせて埋まる。
  /// 長すぎる曲（ミックス音源・配信など）を解析から外す判定に使う。null = 不明
  int? durationMs;

  LoopItem({
    required this.id,
    required this.title,
    required this.uri,
    required this.sourceType,
    this.videoId,
    this.thumbnailUrl,
    this.thumbnailPath,
    this.pointAMs = 0,
    this.pointBMs = 0,
    this.speed = 1.0,
    this.memo,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.fetchStatus,
    List<String>? tagIds,
    this.youtubeUrl,
    List<LoopRegion>? regions,
    this.playCount = 0,
    this.accumulatedPlayMs = 0,
    this.hasSubtitles,
    this.cachedVideoPath,
    this.cachedSubtitlePath,
    this.cachedResolution,
    this.cachedSizeBytes,
    this.cachedAt,
    this.bpm,
    this.musicalKey,
    this.analyzedAt,
    this.analysisVersion,
    this.leadingSilenceMs,
    this.trailingSilenceMs,
    this.musicHeadMs,
    this.musicTailMs,
    this.notMusic,
    this.tempoSectionData,
    this.keySectionData,
    this.sectionGridData,
    this.mixInMs,
    this.mixOutMs,
    this.beatOffsetMs,
    this.beatBpm,
    this.beatConfidence,
    this.downbeatMs,
    this.downbeatConfidence,
    this.headDb,
    this.tailDb,
    this.endFadeDb,
    this.dropDb,
    this.energyDb,
    this.loudnessDb,
    this.firstVerseAMs,
    this.firstVerseBMs,
    this.durationMs,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        tagIds = tagIds ?? [],
        regions = regions ?? [];

  /// 再生カウントのしきい値（ミリ秒）
  static int playCountThresholdMs(int durationMs) {
    if (durationMs <= 30000) return durationMs; // ≤30秒: 全部
    if (durationMs >= 600000) return 480000; // ≥10分: 8分固定
    return (durationMs * 0.8).round(); // その間: 80%
  }

  /// 拍の格子（両方の値が揃っているときだけ）
  BeatGrid? get beatGrid => beatBpm != null && beatOffsetMs != null
      ? BeatGrid(
          bpm: beatBpm!,
          offsetMs: beatOffsetMs!,
          confidence: beatConfidence ?? 1,
          downbeatMs: downbeatMs,
          downbeatConfidence: downbeatConfidence)
      : null;

  /// 拍の線の材料（[BeatGrid.barGrid] と同じ基準で何拍目かを数える）。
  /// 格子が無い・信用できない曲は null（ずれた線を出しても惑わせるだけ）
  BeatLineSource? get beatLines {
    final grid = beatGrid;
    if (grid == null || !grid.reliable) return null;
    return (grid: grid, anchorMs: mixInMs?.toDouble());
  }

  /// YouTube由来か（文字列比較を19箇所に散らさないための入口）
  bool get isYouTube => sourceType == SourceTypes.youtube;

  /// ローカルファイル由来か
  bool get isLocal => sourceType == SourceTypes.local;

  bool get isFetching => fetchStatus == 'fetching';
  bool get hasError => fetchStatus != null && fetchStatus!.startsWith('error');
  bool get isReady => fetchStatus == null;

  /// オフライン再生用の動画がダウンロード済みか
  bool get isCached => cachedVideoPath != null;

  /// オフライン保存の解像度欄に入れる「音声だけ保存した」印
  static const audioOnlyResolution = '音声のみ';

  /// オフライン保存したのが音声だけか（映像は無い）
  bool get isCachedAudioOnly =>
      isCached && cachedResolution == audioOnlyResolution;
  String? get errorMessage =>
      hasError ? fetchStatus!.substring('error:'.length) : null;

  /// regions が空でレガシーAB値がある場合はregionsに昇格してから返す（後方互換）
  /// それ以外は空リスト（= 全体再生）
  /// 表示用の区間リスト。
  ///
  /// 旧バージョンのAB値しか持たないアイテムでは、それを区間1つとして「見せる」だけで
  /// **[regions] は書き換えない**。以前はここで昇格させていたため、
  /// 読んだだけで区間が生成され、後続のsaveでユーザーが作っていない区間が
  /// 永続化されてしまっていた。
  /// 区間を編集する場合は [ensureRegions] を使うこと。
  List<LoopRegion> get effectiveRegions {
    if (regions.isNotEmpty) return regions;
    if (pointAMs > 0 || pointBMs > 0) return [_legacyRegion()];
    return [];
  }

  /// 区間を直接編集する前に呼ぶ。
  /// レガシーAB値しか無ければ区間へ昇格させ、[regions] 本体を返す。
  List<LoopRegion> ensureRegions() {
    if (regions.isEmpty && (pointAMs > 0 || pointBMs > 0)) {
      regions.add(_legacyRegion());
    }
    return regions;
  }

  /// 表示用の BPM（「120 BPM」）。未解析なら null
  String? get bpmLabel => bpm != null
      ? formatBpm(bpm!, tempoSections)
      : notMusic == true
          ? 'BPM —'
          : null;

  /// 「120 BPM」。テンポが変わる曲は「150 BPM（100〜150）」（メインの値 + 区切りの最小〜最大）
  static String formatBpm(double bpm, List<TempoSection> sections) {
    final main = '${bpm.round()} BPM';
    if (sections.length < 2) return main;
    final values = [for (final s in sections) s.bpm.round()];
    final lo = values.reduce(min), hi = values.reduce(max);
    return lo == hi ? main : '$main（$lo〜$hi）';
  }

  /// 曲名の下などに並べる BPM とキー。表記はどの画面でも同じ
  /// （以前は「BPM 120」と「120 BPM」が画面ごとに混在していた）
  List<String> get musicInfoParts => [?bpmLabel, ?keyLabel];

  /// 区間の一覧を差し替える。旧バージョン互換の [pointAMs]/[pointBMs] は先頭の区間に
  /// 合わせる（区間なしなら 0）。保存前に必ずこれを通す（以前は画面ごとに同じ 4 行が
  /// あり、AB 設定画面は区間なしのとき旧値を残していたので、消した区間が
  /// [effectiveRegions] で蘇っていた）
  void setRegions(List<LoopRegion> list) {
    regions = List.from(list);
    pointAMs = regions.isEmpty ? 0 : regions.first.pointAMs ?? 0;
    pointBMs = regions.isEmpty ? 0 : regions.first.pointBMs ?? 0;
  }

  LoopRegion _legacyRegion() => LoopRegion(
        id: 'default',
        name: '区間 1',
        pointAMs: pointAMs > 0 ? pointAMs : null,
        pointBMs: pointBMs > 0 ? pointBMs : null,
      );
}

class LoopItemAdapter extends TypeAdapter<LoopItem> {
  @override
  final int typeId = 0;

  @override
  LoopItem read(BinaryReader reader) {
    final fields = reader.readMap().cast<int, dynamic>();
    return LoopItem(
      id: fields[0] as String,
      title: fields[1] as String,
      uri: fields[2] as String,
      sourceType: fields[3] as String,
      videoId: fields[4] as String?,
      thumbnailUrl: fields[5] as String?,
      thumbnailPath: fields[6] as String?,
      pointAMs: fields[7] as int? ?? 0,
      pointBMs: fields[8] as int? ?? 0,
      speed: (fields[9] as num?)?.toDouble() ?? 1.0,
      memo: fields[10] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(fields[11] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(fields[12] as int),
      fetchStatus: fields[13] as String?,
      tagIds: (fields[14] as List?)?.cast<String>() ?? [],
      youtubeUrl: fields[15] as String?,
      regions: (fields[16] as List?)
              ?.map((m) => LoopRegion.fromMap((m as Map).cast<String, dynamic>()))
              .toList() ??
          [],
      playCount: fields[17] as int? ?? 0,
      accumulatedPlayMs: fields[18] as int? ?? 0,
      hasSubtitles: fields[19] as bool?,
      cachedVideoPath: fields[20] as String?,
      cachedSubtitlePath: fields[21] as String?,
      cachedResolution: fields[22] as String?,
      cachedSizeBytes: fields[23] as int?,
      cachedAt: fields[24] as int?,
      bpm: (fields[25] as num?)?.toDouble(),
      musicalKey: fields[26] as String?,
      analyzedAt: fields[27] as int?,
      leadingSilenceMs: fields[28] as int?,
      trailingSilenceMs: fields[29] as int?,
      mixInMs: fields[30] as int?,
      mixOutMs: fields[31] as int?,
      beatOffsetMs: (fields[32] as num?)?.toDouble(),
      beatBpm: (fields[33] as num?)?.toDouble(),
      durationMs: fields[34] as int?,
      analysisVersion: fields[35] as int?,
      beatConfidence: (fields[36] as num?)?.toDouble(),
      headDb: (fields[37] as num?)?.toDouble(),
      tailDb: (fields[38] as num?)?.toDouble(),
      endFadeDb: (fields[39] as num?)?.toDouble(),
      dropDb: (fields[40] as num?)?.toDouble(),
      loudnessDb: (fields[41] as num?)?.toDouble(),
      firstVerseAMs: fields[42] as int?,
      firstVerseBMs: fields[43] as int?,
      downbeatMs: (fields[44] as num?)?.toDouble(),
      downbeatConfidence: (fields[45] as num?)?.toDouble(),
      energyDb: (fields[46] as List?)?.map((v) => (v as num).toDouble()).toList(),
      musicHeadMs: fields[47] as int?,
      musicTailMs: fields[48] as int?,
      notMusic: fields[49] as bool?,
      tempoSectionData:
          (fields[50] as List?)?.map((v) => (v as num).toDouble()).toList(),
      keySectionData: (fields[51] as List?)?.cast<String>(),
      sectionGridData:
          (fields[52] as List?)?.map((v) => (v as num).toDouble()).toList(),
    );
  }

  @override
  void write(BinaryWriter writer, LoopItem obj) {
    writer.writeMap({
      0: obj.id,
      1: obj.title,
      2: obj.uri,
      3: obj.sourceType,
      4: obj.videoId,
      5: obj.thumbnailUrl,
      6: obj.thumbnailPath,
      7: obj.pointAMs,
      8: obj.pointBMs,
      9: obj.speed,
      10: obj.memo,
      11: obj.createdAt.millisecondsSinceEpoch,
      12: obj.updatedAt.millisecondsSinceEpoch,
      13: obj.fetchStatus,
      14: obj.tagIds,
      15: obj.youtubeUrl,
      16: obj.regions.map((r) => r.toMap()).toList(),
      17: obj.playCount,
      18: obj.accumulatedPlayMs,
      19: obj.hasSubtitles,
      20: obj.cachedVideoPath,
      21: obj.cachedSubtitlePath,
      22: obj.cachedResolution,
      23: obj.cachedSizeBytes,
      24: obj.cachedAt,
      25: obj.bpm,
      26: obj.musicalKey,
      27: obj.analyzedAt,
      28: obj.leadingSilenceMs,
      29: obj.trailingSilenceMs,
      30: obj.mixInMs,
      31: obj.mixOutMs,
      32: obj.beatOffsetMs,
      33: obj.beatBpm,
      34: obj.durationMs,
      35: obj.analysisVersion,
      36: obj.beatConfidence,
      37: obj.headDb,
      38: obj.tailDb,
      39: obj.endFadeDb,
      40: obj.dropDb,
      41: obj.loudnessDb,
      42: obj.firstVerseAMs,
      43: obj.firstVerseBMs,
      44: obj.downbeatMs,
      45: obj.downbeatConfidence,
      46: obj.energyDb,
      47: obj.musicHeadMs,
      48: obj.musicTailMs,
      49: obj.notMusic,
      50: obj.tempoSectionData,
      51: obj.keySectionData,
      52: obj.sectionGridData,
    });
  }
}
