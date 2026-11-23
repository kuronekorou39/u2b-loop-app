import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../core/storage/app_boxes.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/request_pacing.dart';
import '../models/loop_item.dart';
import '../services/thumbnail_service.dart';
import 'data_provider.dart';

/// まとめて取得の進み具合。null = まとめて取得するものが無い
@immutable
class ThumbnailQueueState {
  const ThumbnailQueueState({
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.remaining,
    this.paused = false,
  });

  /// まとめて取得する件数（0 = まだ数えている）
  final int total;
  final int done;
  final int failed;

  /// 残り時間の見込み（件数が分かった時点から出る）
  final Duration? remaining;

  /// 一時停止中（曲単体・再生中の曲の取得は通る）
  final bool paused;

  bool get running => !paused;

  ThumbnailQueueState copyWith({
    int? total,
    int? done,
    int? failed,
    Duration? remaining,
    bool? paused,
  }) =>
      ThumbnailQueueState(
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        remaining: remaining ?? this.remaining,
        paused: paused ?? this.paused,
      );
}

/// サムネイルの取得係。復元・プレイリスト読み込み・共有の取り込み・曲単体・再生中の曲が
/// すべて同じ列に並ぶ。
/// **制限されないよう常に 1 件ずつ、[RequestPacing] の間隔を空けて取る（並列にしない）**。
///
/// - まとめて取得は一時停止・再開できる。止めてもアプリを閉じても、続きは
///   「サムネイルの無い曲」を数え直すだけで分かる
/// - 曲単体（[fetchNow]）と再生する曲（[fetchIfMissing]）は列の先頭に入り、一時停止中でも通る
/// - 取れなかった曲は覚えておき、自動では取りに行かない（手動の取得・再試行では取り直す）
/// - 続けて失敗したら通信できていないとみなして一時停止する（制限中に叩き続けない）
final thumbnailQueueProvider =
    StateNotifierProvider<ThumbnailQueueNotifier, ThumbnailQueueState?>(
        (ref) => ThumbnailQueueNotifier(ref));

/// 1 曲ぶんの取得（保存先のパス、失敗なら null）。テストで差し替える
typedef FetchThumbnail = Future<String?> Function(LoopItem item);

class ThumbnailQueueNotifier extends StateNotifier<ThumbnailQueueState?> {
  ThumbnailQueueNotifier(
    this._ref, {
    FetchThumbnail? fetch,
    RequestPacing? pacing,
    Future<void> Function(Duration)? wait,
  })  : _fetch = fetch ?? _defaultFetch,
        _pacing = pacing ?? LoopItemsNotifier.requestPacing,
        _wait = wait ?? Future<void>.delayed,
        super(null);

  /// 実測が出るまでの 1 件の見込み（画像の取得 / 動画からの生成）
  static const assumedDownloadMs = 300;
  static const assumedGenerateMs = 800;

  /// まとめて取得がこの件数続けて失敗したら一時停止する
  static const failStreakLimit = 10;

  /// 一覧へ反映する間隔（1 件ごとに並べ直すと 1000 曲で画面が重くなる）
  static const _saveInterval = Duration(seconds: 1);

  final Ref _ref;
  final FetchThumbnail _fetch;
  final RequestPacing _pacing;
  final Future<void> Function(Duration) _wait;

  /// まとめて取得の列（Set リテラルは入れた順を保つ）
  final _bulk = <String>{};
  final _priority = <String>[];
  final _waiters = <String, Completer<bool>>{};
  final _unsaved = <String, String>{};
  final _streak = <String>[];
  Set<String>? _failedCache;
  String? _currentId;
  bool _pumping = false;
  bool _scanning = false;
  bool _paused = false;
  int _session = 0;
  int _downloadMs = 0, _downloads = 0, _generateMs = 0, _generates = 0;

  /// 画像の URL か動画 ID があれば取りに行ける（無ければ動画ファイルから作る）
  static bool _isDownload(LoopItem item) =>
      item.thumbnailUrl != null || item.videoId != null;

  /// サムネイルを用意できる曲か
  static bool canFetch(LoopItem item) =>
      _isDownload(item) || (item.isLocal && item.uri.isNotEmpty);

  static Future<String?> _defaultFetch(LoopItem item) {
    final service = ThumbnailService();
    if (!_isDownload(item)) {
      return service.generateFromVideo(item.id, item.uri);
    }
    final url = item.thumbnailUrl ??
        'https://i.ytimg.com/vi/${item.videoId}/hqdefault.jpg';
    return service.save(item.id, url);
  }

  Set<String> get _failed => _failedCache ??= {
        ...(AppBoxes.settings.get(SettingsKeys.thumbnailFailedIds) as List?)
                ?.cast<String>() ??
            const <String>[],
      };

  void _saveFailed() =>
      AppBoxes.settings.put(SettingsKeys.thumbnailFailedIds, _failed.toList());

  void _setPending(bool value) =>
      AppBoxes.settings.put(SettingsKeys.thumbnailQueuePending, value);

  void _setPaused(bool value) {
    _paused = value;
    AppBoxes.settings.put(SettingsKeys.thumbnailQueuePaused, value);
  }

  // ─── 入口 ───

  /// 起動時: 前回の続きがあれば戻す（一時停止していたら止まったまま）
  Future<void> restoreOnLaunch() async {
    final settings = AppBoxes.settings;
    if (settings.get(SettingsKeys.thumbnailQueuePending, defaultValue: false) !=
        true) {
      return;
    }
    if (settings.get(SettingsKeys.thumbnailQueuePaused, defaultValue: false) !=
        true) {
      await startAll(retryFailed: false);
      return;
    }
    _paused = true;
    final targets =
        await _ref.read(loopItemsProvider.notifier).missingThumbnails();
    if (!mounted) return;
    _add(targets.map((i) => i.id).where((id) => !_failed.contains(id)));
    if (_bulk.isEmpty) {
      _setPaused(false);
      _setPending(false);
    }
  }

  /// サムネイルの無い曲をすべて列に入れる。[retryFailed] なら前に取れなかった曲も
  Future<void> startAll({bool retryFailed = true}) async {
    final s = state;
    if (_scanning || (s != null && s.running)) return;
    _scanning = true;
    _setPaused(false);
    _setPending(true);
    if (retryFailed && _failed.isNotEmpty) {
      _failed.clear();
      _saveFailed();
    }
    state = s?.copyWith(paused: false) ?? const ThumbnailQueueState();
    try {
      final targets =
          await _ref.read(loopItemsProvider.notifier).missingThumbnails();
      if (!mounted) return;
      _add(targets.map((i) => i.id).where((id) => !_failed.contains(id)));
    } catch (_) {
      if (mounted) {
        AppToast.instance.show(AppSnackBar.error('サムネイルの取得を始められませんでした'));
      }
    } finally {
      _scanning = false;
    }
    if (!mounted) return;
    _finishIfDone();
    unawaited(_pump());
  }

  /// 追加された曲を列の後ろに入れる（一時停止中なら再開まで待つ）
  void enqueue(Iterable<String> ids) {
    final targets = ids.where((id) {
      final item = AppBoxes.loopItems.get(id);
      return item != null && item.thumbnailPath == null && canFetch(item);
    });
    _add(targets);
    unawaited(_pump());
  }

  /// 曲単体の取得。列の先頭に入り、一時停止中でも通る。前に失敗した曲も取り直す
  Future<bool> fetchNow(String id) {
    final waiter = _waiters.putIfAbsent(id, Completer<bool>.new);
    if (_currentId != id) {
      _priority
        ..remove(id)
        ..insert(0, id);
      unawaited(_pump());
    }
    return waiter.future;
  }

  /// 再生する曲にサムネイルが無ければ取る。一時停止中でも通る。前に失敗した曲は取りに行かない
  void fetchIfMissing(LoopItem item) {
    if (!Hive.isBoxOpen(AppBoxes.loopItemsName)) return;
    final id = item.id;
    if (item.thumbnailPath != null ||
        !canFetch(item) ||
        _failed.contains(id) ||
        _currentId == id ||
        _priority.contains(id)) {
      return;
    }
    _priority.insert(0, id);
    unawaited(_pump());
  }

  void pause() {
    final s = state;
    if (s == null || s.paused) return;
    _setPaused(true);
    state = s.copyWith(paused: true);
    AppToast.instance.show(AppSnackBar.info('一時停止しました。設定の「データ」から再開できます'));
  }

  void resume() {
    final s = state;
    if (s == null || !s.paused) return;
    _setPaused(false);
    state = s.copyWith(paused: false);
    unawaited(_pump());
  }

  /// 列を空にする（復元・全削除で曲が置き換わるとき）
  void clear() {
    _session++;
    _bulk.clear();
    _priority.clear();
    _streak.clear();
    for (final waiter in _waiters.values) {
      waiter.complete(false);
    }
    _waiters.clear();
    _failed.clear();
    _saveFailed();
    _setPaused(false);
    _setPending(false);
    state = null;
  }

  // ─── 列の処理 ───

  void _add(Iterable<String> ids) {
    // 同じ曲が 2 回渡されても 1 件に数える
    final fresh =
        ids.where((id) => id != _currentId && !_bulk.contains(id)).toSet();
    if (fresh.isEmpty) return;
    _bulk.addAll(fresh);
    _setPending(true);
    final s = state ?? ThumbnailQueueState(paused: _paused);
    state = s.copyWith(total: s.total + fresh.length, remaining: _estimate());
  }

  /// 間隔の合計は増え方から決まる。取得そのものの時間だけ、実測の平均で置き換えていく
  Duration _estimate() {
    var downloads = 0, generates = 0;
    for (final id in _bulk) {
      final item = AppBoxes.loopItems.get(id);
      if (item == null) continue;
      if (_isDownload(item)) {
        downloads++;
      } else {
        generates++;
      }
    }
    final perDownload =
        _downloads == 0 ? assumedDownloadMs : _downloadMs ~/ _downloads;
    final perGenerate =
        _generates == 0 ? assumedGenerateMs : _generateMs ~/ _generates;
    return _pacing.upcoming(downloads) +
        Duration(milliseconds: downloads * perDownload + generates * perGenerate);
  }

  bool get _hasWork =>
      _priority.isNotEmpty || (!_paused && _bulk.isNotEmpty);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    final saver = Timer.periodic(_saveInterval, (_) => _save());
    try {
      while (mounted && _hasWork) {
        final String id;
        final bool counted;
        final isPriority = _priority.isNotEmpty;
        if (isPriority) {
          id = _priority.removeAt(0);
          counted = _bulk.remove(id);
        } else {
          id = _bulk.first;
          _bulk.remove(id);
          counted = true;
        }
        await _handle(id, counted: counted, saveNow: isPriority);
      }
    } finally {
      saver.cancel();
      _pumping = false;
      if (mounted) await _save();
      if (mounted) _finishIfDone();
    }
  }

  Future<void> _handle(
    String id, {
    required bool counted,
    required bool saveNow,
  }) async {
    final session = _session;
    final item = AppBoxes.loopItems.get(id);
    final existing = item?.thumbnailPath;
    final hasFile = existing != null && await File(existing).exists();
    if (!mounted) return;
    final shouldFetch = item != null && !hasFile && canFetch(item);

    String? path;
    if (shouldFetch) {
      _currentId = id;
      final watch = Stopwatch()..start();
      try {
        path = await _fetch(item);
      } catch (_) {}
      _currentId = null;
      if (!mounted) return;
      if (_isDownload(item)) {
        _downloadMs += watch.elapsedMilliseconds;
        _downloads++;
      } else {
        _generateMs += watch.elapsedMilliseconds;
        _generates++;
      }
      if (path != null) {
        _unsaved[id] = path;
        if (_failed.remove(id)) _saveFailed();
        if (saveNow) await _save();
        if (!mounted) return;
      } else if (session == _session && _failed.add(id)) {
        _saveFailed();
      }
    }

    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(shouldFetch ? path != null : hasFile);
    }

    final delay =
        shouldFetch && _isDownload(item) ? _pacing.next() : null;
    if (counted && session == _session) {
      final s = state;
      if (s != null) {
        final failedNow = shouldFetch && path == null;
        state = s.copyWith(
          done: s.done + 1,
          failed: s.failed + (failedNow ? 1 : 0),
          remaining: _estimate(),
        );
        if (shouldFetch) _trackStreak(id, failedNow);
      }
    }
    // 終わりの表示は待たずに出すが、次の取得までの間隔は必ず空ける
    if (!_hasWork) _finishIfDone();
    if (delay != null) await _wait(delay);
  }

  /// 続けて失敗したら、その分を列に戻して一時停止する（取れない曲として覚えない）
  void _trackStreak(String id, bool failed) {
    if (!failed) {
      _streak.clear();
      return;
    }
    _streak.add(id);
    if (_streak.length < failStreakLimit) return;
    final back = List.of(_streak);
    _streak.clear();
    final rest = _bulk.toList();
    _bulk
      ..clear()
      ..addAll(back)
      ..addAll(rest);
    _failed.removeAll(back);
    _saveFailed();
    final s = state!;
    _setPaused(true);
    state = s.copyWith(
      done: s.done - back.length,
      failed: s.failed - back.length,
      remaining: _estimate(),
      paused: true,
    );
    AppToast.instance.show(
        AppSnackBar.error('サムネイルを続けて取得できないので一時停止しました'));
  }

  Future<void> _save() async {
    if (_unsaved.isEmpty) return;
    final batch = Map<String, String>.of(_unsaved);
    _unsaved.clear();
    await _ref.read(loopItemsProvider.notifier).saveThumbnailPaths(batch);
  }

  void _finishIfDone() {
    final last = state;
    if (last == null || _scanning || _bulk.isNotEmpty) return;
    state = null;
    _streak.clear();
    _setPaused(false);
    _setPending(false);
    if (last.total > 0) _announce(last);
  }

  void _announce(ThumbnailQueueState s) {
    final toast = AppToast.instance;
    if (s.failed > 0) {
      toast.show(AppSnackBar.action(
        '${s.failed} 件のサムネイルを取得できませんでした',
        label: '再試行',
        onPressed: startAll,
      ));
    } else {
      toast.show(AppSnackBar.success('サムネイルを ${s.total} 件取得しました'));
    }
  }
}
