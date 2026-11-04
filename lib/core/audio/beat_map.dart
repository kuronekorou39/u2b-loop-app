import '../../models/loop_item.dart';
import 'beat_grid.dart';
import 'musical_key.dart';

/// 拍の格子が効く範囲（曲の時刻、ミリ秒）
class BeatSegment {
  const BeatSegment(this.fromMs, this.toMs, this.grid, {this.anchorMs});
  final double fromMs;
  final double toMs;
  final BeatGrid grid;

  /// 小節頭が分からないときの基準（ドロップなど）
  final double? anchorMs;
}

/// テンポ・キーの変わり目（曲の時刻、ミリ秒）と波形に出すラベル
class SectionMarker {
  const SectionMarker(this.ms, this.label, {required this.isKey});
  final double ms;
  final String label;

  /// キーの変わり目（false ならテンポの変わり目）
  final bool isKey;
}

/// 曲の拍の線と変わり目を、波形に描ける形にする（純Dart）
class BeatMap {
  BeatMap._();

  /// 拍の線を引く範囲と格子。テンポが一定なら曲全体を [LoopItem.beatGrid] で。
  /// 変わる曲は区切りごとに、一番長い区切りは [LoopItem.beatGrid]（ジョグ・フェーダーで
  /// 直した値）、ほかは区切りごとに求めた格子で。信用できない格子の範囲は線を引かない
  static List<BeatSegment> segmentsOf(LoopItem item) {
    final main = item.beatGrid;
    final anchor = item.mixInMs?.toDouble();
    final sections = item.tempoSections;
    if (sections.length < 2) {
      return main != null && main.reliable
          ? [BeatSegment(0, double.infinity, main, anchorMs: anchor)]
          : const [];
    }
    final grids = item.sectionGrids;
    final mainIndex = item.mainTempoSectionIndex;
    return [
      for (var i = 0; i < sections.length; i++)
        if ((i == mainIndex ? main : (i < grids.length ? grids[i] : null))
            case final g? when g.reliable)
          BeatSegment(
            sections[i].startMs.toDouble(),
            i + 1 < sections.length
                ? sections[i + 1].startMs.toDouble()
                : double.infinity,
            g,
            anchorMs: i == mainIndex ? anchor : null,
          ),
    ];
  }

  /// テンポとキーの変わり目（最初の区切りの頭は出さない）。ラベルは「110 BPM」「Bm」
  static List<SectionMarker> markersOf(LoopItem item) => [
        for (final s in item.tempoSections.skip(1))
          SectionMarker(s.startMs.toDouble(), '${s.bpm.round()} BPM',
              isKey: false),
        for (final s in item.keySections.skip(1))
          SectionMarker(s.startMs.toDouble(), shortKey(s.key), isKey: true),
      ];

  /// 'Bmin' → 'Bm'、'A#maj' → 'A#'
  static String shortKey(String key) {
    final parsed = MusicalKey.parse(key);
    if (parsed == null) return key;
    return '${MusicalKey.notes[parsed.$1]}${parsed.$2 == KeyMode.minor ? 'm' : ''}';
  }
}
