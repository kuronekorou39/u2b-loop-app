import 'package:hive/hive.dart';
import 'loop_region.dart';

class LoopItem {
  String id;
  String title;
  String uri;
  String sourceType; // 'youtube' or 'local'
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
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        tagIds = tagIds ?? [],
        regions = regions ?? [];

  bool get isFetching => fetchStatus == 'fetching';
  bool get hasError => fetchStatus != null && fetchStatus!.startsWith('error');
  bool get isReady => fetchStatus == null;
  String? get errorMessage =>
      hasError ? fetchStatus!.substring('error:'.length) : null;

  /// regions が空なら pointA/B またはデフォルト1件を返す
  List<LoopRegion> get effectiveRegions {
    if (regions.isNotEmpty) return regions;
    return [
      LoopRegion(
        id: 'default',
        name: '区間 1',
        pointAMs: pointAMs > 0 ? pointAMs : null,
        pointBMs: pointBMs > 0 ? pointBMs : null,
      )
    ];
  }
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
    });
  }
}
