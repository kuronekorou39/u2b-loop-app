import 'loop_item.dart';
import 'loop_region.dart';

class PlaylistTrack {
  final LoopItem item;
  final LoopRegion? region;
  final int itemIndex;
  final int regionIndex;
  bool enabled;

  PlaylistTrack({
    required this.item,
    this.region,
    required this.itemIndex,
    this.regionIndex = -1,
    this.enabled = true,
  });

  int? get startMs => region?.pointAMs;
  int? get endMs => region?.pointBMs;
  bool get hasRegion => region != null && region!.hasPoints;

  String get displayName {
    if (region != null && region!.name != '区間 1') {
      return '${item.title} - ${region!.name}';
    }
    return item.title;
  }

  /// 同一LoopItemかどうか
  bool isSameItem(PlaylistTrack other) => item.id == other.item.id;
}
