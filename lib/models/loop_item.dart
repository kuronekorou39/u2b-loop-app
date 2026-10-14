import 'package:hive/hive.dart';
import '../core/audio/beat_grid.dart';
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

  /// 曲頭の無音（ミリ秒）。クロスフェードで無音同士を重ねないために使う。
  /// null = 未計測（v1.72 以前の解析結果。再解析で埋まる）
  int? leadingSilenceMs;

  /// 曲末の無音（ミリ秒）。null = 未計測、または曲が長すぎて曲末まで解析していない
  int? trailingSilenceMs;

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
    this.leadingSilenceMs,
    this.trailingSilenceMs,
    this.mixInMs,
    this.mixOutMs,
    this.beatOffsetMs,
    this.beatBpm,
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
      ? BeatGrid(bpm: beatBpm!, offsetMs: beatOffsetMs!)
      : null;

  /// YouTube由来か（文字列比較を19箇所に散らさないための入口）
  bool get isYouTube => sourceType == SourceTypes.youtube;

  /// ローカルファイル由来か
  bool get isLocal => sourceType == SourceTypes.local;

  bool get isFetching => fetchStatus == 'fetching';
  bool get hasError => fetchStatus != null && fetchStatus!.startsWith('error');
  bool get isReady => fetchStatus == null;

  /// オフライン再生用の動画がダウンロード済みか
  bool get isCached => cachedVideoPath != null;
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
    });
  }
}
