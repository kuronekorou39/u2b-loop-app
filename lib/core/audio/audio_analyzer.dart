import 'dart:math';
import 'dart:typed_data';

import 'beat_grid.dart';
import 'bpm_key_detector.dart';
import 'cq_chroma.dart';
import 'key_sections.dart';
import 'music_span_detector.dart';
import 'tempo_resolver.dart';
import 'tempo_sections.dart';

class AudioAnalysisResult {
  const AudioAnalysisResult({
    required this.bpmCandidates,
    required this.keyCandidates,
    this.beatGrid,
    this.baseGrid,
    this.span = MusicSpan.whole,
    this.sections = const [],
    this.keySections = const [],
    this.sectionGrids = const [],
  });
  final List<BpmCandidate> bpmCandidates;
  final List<KeyCandidate> keyCandidates;

  /// 曲が鳴っている範囲。BPM・キー・拍の格子はこの範囲だけで求めてある
  final MusicSpan span;

  /// 1 位の BPM で求めた拍の格子と小節頭（BPM が無ければ null）。
  /// テンポが変わる曲では一番長い区切りで求めたもの
  final BeatGrid? beatGrid;

  /// テンポの取り違えを直す前の格子。解析し直すとき、保存されている格子がこれと同じなら
  /// 自動で求めたもの（新しい [beatGrid] に置き換えてよい）、違えば手で直したもの
  final BeatGrid? baseGrid;

  /// テンポの区切り（テンポが変わる曲だけ。一定なら空）
  final List<TempoSection> sections;

  /// キーの区切り（転調する曲だけ。一定なら空）。[key] は一番長い区切りのキー
  final List<KeySection> keySections;

  /// テンポの区切りごとの拍の格子（[sections] と同じ並び。求められなければ null）。
  /// 一番長い区切りは [beatGrid] と同じもの。テンポが一定なら空
  final List<BeatGrid?> sectionGrids;

  double? get bpm => bpmCandidates.isEmpty ? null : bpmCandidates.first.bpm;
  String? get key => keyCandidates.isEmpty ? null : keyCandidates.first.key;
}

/// 曲全体の解析の手順（純Dart・副作用なし。重いので呼び出し側で isolate に載せること）。
/// 部品は [BpmKeyDetector] と、曲の範囲・テンポの区切り・キーの区切りの検出
class AudioAnalyzer {
  AudioAnalyzer._();

  /// 曲の範囲（[MusicSpanDetector]）を求め、その中だけで BPM・キー・拍の格子を求める。
  /// 曲ではないと判定したら BPM・キー・格子は空。
  /// テンポが変わる曲（[TempoSectionDetector]）は、BPM・拍の格子を一番長い区切りだけで求める
  static AudioAnalysisResult analyze(Int16List pcm, int sampleRate) {
    final whole = BpmKeyDetector.onsetEnvelope(pcm, sampleRate);
    final span = whole == null ? MusicSpan.whole : MusicSpanDetector.detect(whole);
    int sample(int ms) => (ms * sampleRate / 1000).round().clamp(0, pcm.length);
    if (!span.isMusic) {
      // 拍がはっきりしなくても、和音があれば曲（テンポを揺らすバラードなど）。キーだけ出す
      final chroma = CqChroma.frames(pcm, sampleRate);
      final tonal = MusicSpanDetector.tonalSpan(chroma, sampleRate);
      if (!tonal.isMusic) {
        return AudioAnalysisResult(
            bpmCandidates: const [], keyCandidates: const [], span: span);
      }
      final from = sample(tonal.startMs);
      final to = tonal.endMs == null ? pcm.length : max(from, sample(tonal.endMs!));
      final fps = sampleRate / CqChroma.hop;
      final part = chroma.sublist(
          min(chroma.length, (from / CqChroma.hop).floor()),
          min(chroma.length, (to / CqChroma.hop).ceil()));
      final keySections =
          KeySectionDetector.detect(part, sampleRate, startMs: tonal.startMs);
      return AudioAnalysisResult(
        bpmCandidates: const [],
        keyCandidates: _mainKey(keySections, CqChroma.sum(part),
            endMs: tonal.startMs + (part.length * 1000 / fps).round()),
        span: tonal,
        keySections: keySections,
      );
    }
    final from = sample(span.startMs);
    final to = span.endMs == null ? pcm.length : max(from, sample(span.endMs!));
    final musicPart = Int16List.sublistView(pcm, from, to);

    final sections = whole == null
        ? const <TempoSection>[]
        : TempoSectionDetector.detect(
            whole.slice(whole.frameAt(span.startMs.toDouble()),
                span.endMs == null ? whole.full.length : whole.frameAt(span.endMs!.toDouble())),
            startMs: span.startMs);

    // BPM と格子を求める部分: テンポが一定なら曲の範囲、変わるなら一番長い区切り
    var tempoFrom = from, tempoTo = to;
    TempoSection? main;
    if (sections.length >= 2) {
      var longest = -1;
      for (var i = 0; i < sections.length; i++) {
        final a = sample(sections[i].startMs);
        final b = i + 1 < sections.length ? sample(sections[i + 1].startMs) : to;
        if (b - a > longest) {
          longest = b - a;
          tempoFrom = a;
          tempoTo = b;
          main = sections[i];
        }
      }
    }
    final untouched = tempoFrom == 0 && tempoTo == pcm.length;
    final part = untouched ? pcm : Int16List.sublistView(pcm, tempoFrom, tempoTo);
    final env = untouched ? whole : BpmKeyDetector.onsetEnvelope(part, sampleRate);
    var bpms = env == null
        ? const <BpmCandidate>[]
        : main != null
            ? [BpmCandidate(main.bpm, 1)]
            : BpmKeyDetector.bpmFromEnvelope(env);
    final detected = env == null || bpms.isEmpty
        ? null
        : _gridWithDownbeat(part, sampleRate, env, bpms.first.bpm);
    // 部分の頭を 0 として求めたので、動画の時刻に戻す
    final partStartMs = tempoFrom / sampleRate * 1000;
    final grid = detected?.grid.shiftedBy(partStartMs);
    // BPM は引き直した格子の値に揃える（自己相関の値は刻みが粗く、1% ほどずれている）
    if (grid != null) bpms = [BpmCandidate(_round1(grid.bpm), 1)];
    // ほかの区切りも、その区切りだけで格子（と小節頭）を求める（波形の拍の線を区切りごとに引く）
    final sectionGrids = <BeatGrid?>[
      for (var i = 0; i < sections.length; i++)
        if (identical(sections[i], main))
          grid
        else
          _sectionGrid(pcm, sampleRate, sample(sections[i].startMs),
              i + 1 < sections.length ? sample(sections[i + 1].startMs) : to,
              sections[i].bpm),
    ];
    // 区切りのテンポも格子の値に揃える（表示の範囲とずれないように）
    final outSections = [
      for (var i = 0; i < sections.length; i++)
        switch (sectionGrids[i]) {
          final g? => TempoSection(sections[i].startMs, _round1(g.bpm)),
          null => sections[i],
        },
    ];
    // キー: 曲の範囲のクロマ。転調するなら一番長い区切りのキーを代表にする
    final chroma = CqChroma.frames(musicPart, sampleRate);
    final keySections =
        KeySectionDetector.detect(chroma, sampleRate, startMs: span.startMs);
    final keys = _mainKey(keySections, CqChroma.sum(chroma),
        endMs: span.startMs + musicPart.length * 1000 ~/ sampleRate);
    return AudioAnalysisResult(
      bpmCandidates: bpms,
      keyCandidates: keys,
      beatGrid: grid,
      baseGrid: detected?.base.shiftedBy(partStartMs),
      span: span,
      sections: outSections,
      keySections: keySections,
      sectionGrids: sectionGrids,
    );
  }

  /// 曲のキーの候補: 転調するなら一番長い区切りのキー、しなければ [chroma] 全体から
  static List<KeyCandidate> _mainKey(List<KeySection> sections, Float64List chroma,
      {required int endMs}) {
    if (sections.length < 2) return BpmKeyDetector.keyFromChroma(chroma);
    var longest = 0;
    var keys = const <KeyCandidate>[];
    for (var i = 0; i < sections.length; i++) {
      final next = i + 1 < sections.length ? sections[i + 1].startMs : endMs;
      final len = next - sections[i].startMs;
      if (len > longest) {
        longest = len;
        keys = [KeyCandidate(sections[i].key, 1)];
      }
    }
    return keys;
  }

  /// サンプル [from]〜[to] の区切りの格子（動画の時刻）。短すぎれば null
  static BeatGrid? _sectionGrid(
      Int16List pcm, int sampleRate, int from, int to, double bpm) {
    if (to <= from) return null;
    final part = Int16List.sublistView(pcm, from, to);
    final env = BpmKeyDetector.onsetEnvelope(part, sampleRate);
    if (env == null) return null;
    return _gridWithDownbeat(part, sampleRate, env, bpm)
        ?.grid
        .shiftedBy(from / sampleRate * 1000);
  }

  static double _round1(double v) => (v * 10).round() / 10;

  /// 拍の格子に小節頭を載せたもの。テンポの取り違え（倍・半分・2:3）は格子の精密なテンポで
  /// 確かめて直す（粗いテンポだと 16 拍先で 1 フレーム以上ずれ、音の並びの戻りを測れない）。
  /// [base] は直す前の格子（直さなかったら [grid] と同じ）
  static ({BeatGrid grid, BeatGrid base})? _gridWithDownbeat(
      Int16List pcm, int sampleRate, OnsetEnvelope env, double bpm) {
    final first = BpmKeyDetector.detectBeatGrid(env, bpm);
    if (first == null) return null;
    BeatGrid withBar(BeatGrid g) =>
        g.withDownbeat(BpmKeyDetector.detectDownbeat(pcm, sampleRate, g));
    final flux = BandFlux.of(pcm, sampleRate);
    final resolved =
        flux == null ? first.bpm : TempoResolver.resolve(flux, 0, flux.frames, first.bpm);
    final better = resolved == first.bpm ? null : BpmKeyDetector.detectBeatGrid(env, resolved);
    final base = withBar(first);
    return (grid: better == null ? base : withBar(better), base: base);
  }
}
