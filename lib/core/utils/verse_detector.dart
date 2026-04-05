/// 波形データから「1番が終わる地点」を推定するユーティリティ。
///
/// 波形データ（0.0〜1.0の正規化振幅リスト）と曲の長さから、
/// 50秒〜100秒の範囲で最も音量が小さくなる地点をミリ秒で返す。
class VerseDetector {
  /// 検索開始位置（ミリ秒）
  static const _searchStartMs = 50000; // 50秒

  /// 検索終了位置（ミリ秒）
  static const _searchEndMs = 100000; // 1分40秒

  /// フォールバック切断点（波形なし時）
  static const _fallbackMs = 100000; // 1分40秒

  /// 音量平均を取るウィンドウサイズ（波形サンプル数）
  static const _windowSize = 80;

  /// 波形データから切断点をミリ秒で返す。
  ///
  /// - [waveform]: 正規化振幅データ (0.0〜1.0)。nullなら波形なし。
  /// - [durationMs]: 曲全体の長さ（ミリ秒）。
  ///
  /// 戻り値: 切断点のミリ秒。nullなら全曲再生（50秒未満の曲）。
  static int? findCutPoint({
    List<double>? waveform,
    required int durationMs,
  }) {
    // 50秒未満 → 全部流す
    if (durationMs < _searchStartMs) return null;

    // 曲全体が検索範囲内 → 全部流す
    if (durationMs <= _searchEndMs) return null;

    // 波形なし or サンプル不足 → フォールバック
    if (waveform == null || waveform.length < 100) {
      return _fallbackMs;
    }

    final msPerSample = durationMs / waveform.length;
    final searchStart = (_searchStartMs / msPerSample).round();
    final searchEnd =
        (_searchEndMs / msPerSample).round().clamp(0, waveform.length);

    if (searchStart >= searchEnd) return _fallbackMs;

    // スライディングウィンドウで平均振幅が最小の地点を探す
    double minAvg = double.infinity;
    int minIdx = searchStart;

    final windowHalf = _windowSize ~/ 2;
    for (var i = searchStart; i < searchEnd; i++) {
      final wStart = (i - windowHalf).clamp(0, waveform.length - 1);
      final wEnd = (i + windowHalf).clamp(0, waveform.length);
      double sum = 0;
      for (var j = wStart; j < wEnd; j++) {
        sum += waveform[j];
      }
      final avg = sum / (wEnd - wStart);
      if (avg < minAvg) {
        minAvg = avg;
        minIdx = i;
      }
    }

    // サンプルインデックス → ミリ秒に変換
    return (minIdx * msPerSample).round();
  }
}
