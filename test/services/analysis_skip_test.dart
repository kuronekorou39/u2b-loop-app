import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/services/audio_analysis_service.dart';

LoopItem _item({int? durationMs, int? analyzedAt, int? leadingSilenceMs}) =>
    LoopItem(
      id: 'x',
      title: 't',
      uri: 'u',
      sourceType: SourceTypes.local,
      durationMs: durationMs,
      analyzedAt: analyzedAt,
      leadingSilenceMs: leadingSilenceMs,
    );

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  test('10 分より長い曲は解析しない（長さ不明なら対象）', () {
    expect(AudioAnalysisService.isTooLong(_item(durationMs: 10 * 60 * 1000 + 1)), isTrue);
    expect(AudioAnalysisService.isTooLong(_item(durationMs: 10 * 60 * 1000)), isFalse);
    expect(AudioAnalysisService.isTooLong(_item()), isFalse);

    expect(AudioAnalysisService.needsAnalysis(_item(durationMs: 60 * 60 * 1000)), isFalse);
    expect(AudioAnalysisService.needsAnalysis(_item(durationMs: 4 * 60 * 1000)), isTrue);
    expect(AudioAnalysisService.needsAnalysis(_item()), isTrue);
  });

  test('拍の格子を入れる前の解析結果は解析し直す', () {
    expect(
        AudioAnalysisService.needsAnalysis(
            _item(analyzedAt: now, leadingSilenceMs: 0)),
        isFalse);
    expect(
        AudioAnalysisService.needsAnalysis(_item(
            analyzedAt: AudioAnalysisService.beatGridSince - 1,
            leadingSilenceMs: 0)),
        isTrue);
    expect(AudioAnalysisService.needsAnalysis(_item(analyzedAt: now)), isTrue,
        reason: '無音情報が無い旧い解析結果');
  });

  test('長すぎる曲は PCM の受け口を返さない（プレイヤーの長さでも判定）', () {
    expect(AudioAnalysisService.sinkFor(_FakeItems(), _item(), duration: const Duration(minutes: 11)), isNull);
    expect(AudioAnalysisService.sinkFor(_FakeItems(), _item(durationMs: 11 * 60 * 1000)), isNull);
    expect(AudioAnalysisService.sinkFor(_FakeItems(), _item(), duration: const Duration(minutes: 3)), isNotNull);
  });
}

/// sinkFor は受け口を返すだけで items には触れない
class _FakeItems implements LoopItemsNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
