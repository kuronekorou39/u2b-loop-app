import '../../models/loop_region.dart';

/// 区間を順につなぐときの決まり（連続再生と、全区間の書き出しで共通）。
///
/// 並びは一覧の順。A・B が揃っていて A < B の区間だけを使う
class RegionSequence {
  RegionSequence._();

  static bool isPlayable(LoopRegion r) =>
      r.hasA && r.hasB && r.pointAMs! < r.pointBMs!;

  static List<int> playableIndexes(List<LoopRegion> regions) => [
        for (var i = 0; i < regions.length; i++)
          if (isPlayable(regions[i])) i,
      ];

  /// つなげるのは使える区間が 2 つ以上あるとき
  static bool canJoin(List<LoopRegion> regions) =>
      playableIndexes(regions).length >= 2;

  /// 連続再生を始める区間: 今の区間が使えればそこ、無ければ最初の使える区間
  static int? startIndex(List<LoopRegion> regions, int current) {
    if (current >= 0 &&
        current < regions.length &&
        isPlayable(regions[current])) {
      return current;
    }
    final playable = playableIndexes(regions);
    return playable.isEmpty ? null : playable.first;
  }

  /// [current] の次の使える区間。最後の次は最初に戻る
  static int? nextIndex(List<LoopRegion> regions, int current) {
    final playable = playableIndexes(regions);
    if (playable.isEmpty) return null;
    for (final i in playable) {
      if (i > current) return i;
    }
    return playable.first;
  }

  /// 書き出す範囲（開始 ms, 終了 ms）を一覧の順に
  static List<(int, int)> ranges(List<LoopRegion> regions) => [
        for (final i in playableIndexes(regions))
          (regions[i].pointAMs!, regions[i].pointBMs!),
      ];

  static int totalMs(List<LoopRegion> regions) =>
      ranges(regions).fold(0, (sum, r) => sum + r.$2 - r.$1);
}
