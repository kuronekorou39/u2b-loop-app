import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import '../core/ui/app_snack_bar.dart';
import '../models/loop_item.dart';
import '../services/audio_analysis_service.dart';
import 'data_provider.dart';
import 'player_provider.dart';

/// まとめて解析の進み具合。null = 動いていない
@immutable
class BulkAnalysisState {
  const BulkAnalysisState({
    required this.playlistId,
    required this.total,
    required this.index,
    required this.currentId,
    required this.currentTitle,
    this.stopping = false,
  });

  /// どのプレイリストから始めたか（画面に進み具合を出す先）
  final String playlistId;
  final int total;

  /// 終わった曲数（いま解析している曲の番号 − 1）
  final int index;

  /// いま解析している曲
  final String currentId;
  final String currentTitle;

  /// 中止を押した（いまの曲が終わったら止まる）
  final bool stopping;

  BulkAnalysisState copyWith({
    int? index,
    String? currentId,
    String? currentTitle,
    bool? stopping,
  }) =>
      BulkAnalysisState(
        playlistId: playlistId,
        total: total,
        index: index ?? this.index,
        currentId: currentId ?? this.currentId,
        currentTitle: currentTitle ?? this.currentTitle,
        stopping: stopping ?? this.stopping,
      );
}

/// テンポ/キーのまとめて解析。画面を閉じても裏で続き、終わったらどの画面でも知らせる。
/// 解析中もアプリは操作できる（並べ替え・タグの編集・解析が済んだ曲の再生など）。
/// 同時に動かすのは 1 つだけ（音声のダウンロードが詰まるので）
final bulkAnalysisProvider =
    StateNotifierProvider<BulkAnalysisNotifier, BulkAnalysisState?>(
        (ref) => BulkAnalysisNotifier(ref));

/// 1 曲の解析（成功なら true）。テストで差し替える
typedef AnalyzeOne = Future<bool> Function(LoopItem item);

class BulkAnalysisNotifier extends StateNotifier<BulkAnalysisState?> {
  BulkAnalysisNotifier(this._ref, {AnalyzeOne? analyze})
      : _analyzeOverride = analyze,
        super(null);

  final Ref _ref;
  final AnalyzeOne? _analyzeOverride;

  Future<bool> _analyze(LoopItem item) async {
    final override = _analyzeOverride;
    if (override != null) return override(item);
    final result = await AudioAnalysisService.analyzeItem(
      _ref.read(loopItemsProvider.notifier),
      _ref.read(youtubeServiceProvider),
      item,
    );
    return result != null;
  }

  bool get running => state != null;

  /// 中止（いまの曲が終わったら止まる）
  void stop() {
    final s = state;
    if (s != null) state = s.copyWith(stopping: true);
  }

  /// [targets] を 1 曲ずつ順に解析する。動いている間は何もしない（false）
  bool start(String playlistId, List<LoopItem> targets) {
    if (running || targets.isEmpty) return false;
    state = BulkAnalysisState(
      playlistId: playlistId,
      total: targets.length,
      index: 0,
      currentId: targets.first.id,
      currentTitle: targets.first.title,
    );
    _run(targets.map((i) => i.id).toList());
    return true;
  }

  /// 終わったときの結果（テスト用。画面へは SnackBar で知らせる）
  ({int done, int skipped, int failed, bool cancelled})? lastResult;

  Future<void> _run(List<String> ids) async {
    var done = 0, skipped = 0, failed = 0;
    for (var i = 0; i < ids.length; i++) {
      final s = state;
      if (s == null || s.stopping) break;
      // 解析中に曲が消されたり、再生で先に解析されたりしているので取り直す
      final item = AppBoxes.loopItems.get(ids[i]);
      if (item == null) continue;
      state = s.copyWith(index: i, currentId: item.id, currentTitle: item.title);
      if (!AudioAnalysisService.needsAnalysis(item)) {
        if (AudioAnalysisService.isTooLong(item)) {
          skipped++;
        } else {
          done++;
        }
        continue;
      }
      final ok = await _analyze(item);
      if (!mounted) return;
      // 再生側が同じ曲を解析中だと null が返るが、その解析で済んでいれば成功に数える
      final fresh = AppBoxes.loopItems.get(item.id);
      if (ok ||
          (fresh != null && !AudioAnalysisService.needsAnalysis(fresh))) {
        done++;
      } else if (AudioAnalysisService.isTooLong(item)) {
        skipped++;
      } else {
        failed++;
      }
    }
    final cancelled = state?.stopping ?? false;
    lastResult =
        (done: done, skipped: skipped, failed: failed, cancelled: cancelled);
    state = null;
    final notes = <String>[
      if (cancelled) '中止',
      if (skipped > 0)
        '$skipped 曲は ${AudioAnalysisService.maxAnalyzableMinutes} 分以上なので省略',
      if (!cancelled && failed > 0) '$failed 曲は取得できず',
    ];
    appMessengerKey.currentState?.showSnackBar(AppSnackBar.success(
      '$done 曲を解析しました${notes.isEmpty ? '' : '（${notes.join('、')}）'}',
    ));
  }
}
