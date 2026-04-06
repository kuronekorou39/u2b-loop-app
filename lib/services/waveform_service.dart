import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class WaveformService {
  static const _channel = MethodChannel('com.u2bloop/waveform');

  /// 前回の抽出をキャンセル（ネイティブ側の MediaExtractor を解放）
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancelExtraction');
    } catch (_) {}
  }

  /// 音声ストリームを一時ファイルにダウンロードしてから波形抽出
  /// （MediaExtractor の setDataSource(url) が player と CDN 接続を競合するため）
  Future<List<double>?> generateFromStream(
      Stream<List<int>> audioStream, int targetSamples) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/u2b_waveform_audio.tmp');
    try {
      debugPrint('[Waveform] ダウンロード開始...');
      final sink = tempFile.openWrite();
      var bytes = 0;
      await for (final chunk in audioStream) {
        sink.add(chunk);
        bytes += chunk.length;
      }
      await sink.flush();
      await sink.close();

      debugPrint('[Waveform] ダウンロード完了: ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB → ${tempFile.path}');

      if (bytes == 0) {
        debugPrint('[Waveform] エラー: ダウンロードファイルが空');
        return null;
      }

      // ローカルファイルとして MediaExtractor に渡す
      return await generateFromUrl(tempFile.path, targetSamples);
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  /// Android MediaExtractorで音声サンプルサイズを取得 → 波形データ化
  /// ローカルファイルパスを渡す（YouTube URL は generateFromAudioUrl を使うこと）
  Future<List<double>?> generateFromUrl(String url, int targetSamples) async {
    final result = await _channel.invokeMethod<List<dynamic>>(
      'extractAmplitudes',
      {'url': url},
    );

    if (result == null || result.isEmpty) {
      return null;
    }

    final amplitudes = result.cast<int>();
    return _downsampleAndNormalize(amplitudes, targetSamples);
  }

  /// ローカルファイルから波形データを生成
  Future<List<double>?> generateForLocalFile(
    String path,
    int targetSamples,
  ) async {
    // まずMediaCodecデコードで試行
    try {
      final result = await generateFromUrl(path, targetSamples);
      if (result != null) return result;
    } catch (_) {
      // MediaCodecが失敗したらフォールバックへ
    }

    // フォールバック: MP4 stszパース
    final file = File(path);
    if (!await file.exists()) return null;
    final data = await file.readAsBytes();

    final mp4Result = _extractFromMp4(data, targetSamples);
    if (mp4Result != null) return mp4Result;

    return _extractFromByteEnergy(data, targetSamples);
  }

  // --- MP4 stsz パーサー (フォールバック用) ---

  List<double>? _extractFromMp4(Uint8List data, int targetSamples) {
    final stszOffsets = <int>[];
    _findAtomsByType(data, 0, data.length, 'stsz', stszOffsets);

    for (final offset in stszOffsets) {
      final result = _parseStszAtom(data, offset, targetSamples);
      if (result != null) return result;
    }
    return null;
  }

  List<double>? _parseStszAtom(
    Uint8List data,
    int atomOffset,
    int targetSamples,
  ) {
    if (atomOffset + 20 > data.length) return null;
    final bd = ByteData.sublistView(data);

    final sampleSize = bd.getUint32(atomOffset + 12);
    final sampleCount = bd.getUint32(atomOffset + 16);

    if (sampleSize != 0) return null;
    if (sampleCount == 0 || sampleCount > 10000000) return null;
    if (atomOffset + 20 + sampleCount * 4 > data.length) return null;

    final sizes = List<int>.generate(
      sampleCount,
      (i) => bd.getUint32(atomOffset + 20 + i * 4),
    );

    return _downsampleAndNormalize(sizes, targetSamples);
  }

  void _findAtomsByType(
    Uint8List data,
    int start,
    int end,
    String target,
    List<int> results,
  ) {
    var offset = start;
    if (end > data.length) end = data.length;
    final bd = ByteData.sublistView(data);

    while (offset + 8 <= end) {
      final size = bd.getUint32(offset);
      if (size < 8 || offset + size > end) break;

      final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));

      if (type == target) {
        results.add(offset);
      }

      const containers = {
        'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'udta',
      };
      if (containers.contains(type)) {
        _findAtomsByType(data, offset + 8, offset + size, target, results);
      }

      offset += size;
    }
  }

  // --- バイトエネルギー解析 ---

  List<double> _extractFromByteEnergy(Uint8List data, int targetSamples) {
    if (data.length < targetSamples * 2) {
      return List.filled(targetSamples, 0.5);
    }

    final chunkSize = data.length ~/ targetSamples;
    final peaks = List<double>.generate(targetSamples, (i) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, data.length - 1);
      var diffSum = 0.0;
      var count = 0;
      for (var j = start; j < end; j++) {
        diffSum += (data[j + 1] - data[j]).abs();
        count++;
      }
      return count > 0 ? diffSum / count : 0;
    });

    final maxPeak = peaks.reduce(max);
    if (maxPeak > 0) {
      for (var i = 0; i < peaks.length; i++) {
        peaks[i] = (peaks[i] / maxPeak).clamp(0.05, 1.0);
      }
    }

    final smoothed = List<double>.filled(targetSamples, 0);
    for (var i = 0; i < targetSamples; i++) {
      final prev = i > 0 ? peaks[i - 1] : peaks[i];
      final next = i < targetSamples - 1 ? peaks[i + 1] : peaks[i];
      smoothed[i] = (prev + peaks[i] + next) / 3;
    }
    return smoothed;
  }

  // --- 共通ユーティリティ ---

  List<double> _downsampleAndNormalize(List<int> sizes, int targetSamples) {
    final n = sizes.length;
    if (n == 0) return List.filled(targetSamples, 0);
    final samplesPerBucket = n / targetSamples;
    final peaks = List<double>.generate(targetSamples, (i) {
      final start = (i * samplesPerBucket).floor();
      final end = min(((i + 1) * samplesPerBucket).floor(), n);
      var maxVal = 0;
      for (var j = start; j < end; j++) {
        if (sizes[j] > maxVal) maxVal = sizes[j];
      }
      return maxVal.toDouble();
    });

    final maxPeak = peaks.reduce(max);
    if (maxPeak > 0) {
      for (var i = 0; i < peaks.length; i++) {
        peaks[i] = peaks[i] / maxPeak;
      }
    }
    return peaks;
  }
}
