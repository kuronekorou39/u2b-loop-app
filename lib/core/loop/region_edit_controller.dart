import '../../models/loop_region.dart';
import '../constants.dart';
import '../utils/id_generator.dart';

/// AB 区間の一覧を編集するときのルール（追加・名前・削除・選択・ループ状態との同期）。
///
/// 再生画面（変更のたびに保存）と AB 設定画面（保存ボタンでまとめて保存）で同じものを使う。
/// 以前は画面ごとに書かれていて、削除できる条件（最後の 1 つ）や、選択中より前の区間を
/// 消したときの選択のずれが揃っていなかった。
///
/// 状態は持ち主の [regions]（その場で書き換える）と [selected] で、このクラスは手順だけ。
/// 保存は持ち主が `LoopItem.setRegions` で行う。
///
/// ルール:
/// - 追加は「区間 N」（N = 件数 + 1）、A = 今の位置、B = 未設定。追加したものを選ぶ
/// - 削除は最後の 1 つもできる（区間なし = 全体を再生）。選択中を消したら同じ位置（次の区間、
///   末尾なら 1 つ前）、選択より前を消したら選択がずれないように詰める
/// - 上限は [maxRegions]
class RegionEditController {
  RegionEditController({
    required this.regions,
    required this.selected,
    this.maxRegions = AppLimits.maxRegions,
  });

  final List<LoopRegion> regions;

  /// 選択中の区間。-1 は「全体」（区間なし）
  int selected;
  final int maxRegions;

  bool get canAdd => regions.length < maxRegions;

  LoopRegion? get current =>
      selected >= 0 && selected < regions.length ? regions[selected] : null;

  static String defaultName(int count) => '区間 ${count + 1}';

  /// 今の位置を A にした区間を末尾に足して選ぶ。上限なら null
  LoopRegion? add({required int positionMs}) {
    if (!canAdd) return null;
    final region = LoopRegion(
      id: IdGenerator.next(),
      name: defaultName(regions.length),
      pointAMs: positionMs,
      pointBMs: null,
    );
    regions.add(region);
    selected = regions.length - 1;
    return region;
  }

  bool rename(int index, String name) {
    if (index < 0 || index >= regions.length) return false;
    regions[index] = regions[index].copyWith(name: name);
    return true;
  }

  /// 削除して選択を詰める。戻り値は削除できたか
  bool delete(int index) {
    if (index < 0 || index >= regions.length) return false;
    regions.removeAt(index);
    if (regions.isEmpty) {
      selected = -1;
    } else if (selected >= 0) {
      if (index < selected) {
        selected--;
      } else if (index == selected) {
        selected = selected.clamp(0, regions.length - 1);
      }
    }
    return true;
  }

  bool select(int index) {
    if (index < -1 || index >= regions.length) return false;
    selected = index;
    return true;
  }

  /// ループ状態（A/B）を選択中の区間へ写す。選択が無ければ何もしない
  void syncFromLoop(Duration? a, Duration? b) {
    final c = current;
    if (c == null) return;
    regions[selected] = c.copyWith(
      pointAMs: () => a?.inMilliseconds,
      pointBMs: () => b?.inMilliseconds,
    );
  }

  /// 名前・A・B のどれかが違えば true（保存の要否に使う）
  static bool differs(List<LoopRegion> a, List<LoopRegion> b) {
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name) return true;
      if (a[i].pointAMs != b[i].pointAMs) return true;
      if (a[i].pointBMs != b[i].pointBMs) return true;
    }
    return false;
  }
}
