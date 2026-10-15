import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/loop_item.dart';
import '../../providers/data_provider.dart';
import '../../providers/subtitle_provider.dart';
import '../subtitle_service.dart';

/// 再生画面の字幕の用意。結果は subtitle_provider の各 provider に流す。
///
/// - [loadFor]: 曲が決まったら呼ぶ。オフライン保存の SRT → YouTube ならネット取得 → 無ければ消す
/// - [fetch]: 言語を選び直したとき（メイン）
/// - [fetchSub]: サブ字幕（小さく出す方）
class SubtitleLoader {
  SubtitleLoader(this._ref, {required this.isMounted});

  final WidgetRef _ref;
  final bool Function() isMounted;

  /// [item] に合う字幕を用意する
  Future<void> loadFor(LoopItem item) {
    if (item.cachedSubtitlePath != null) return loadCached(item);
    if (item.isYouTube && item.videoId != null) return fetch(item);
    clear();
    return Future.value();
  }

  /// 字幕を消す（ローカル動画など、字幕の無い曲に移ったとき）
  void clear() {
    _ref.read(subtitleDataProvider.notifier).state = null;
    _ref.read(subtitleSubDataProvider.notifier).state = null;
  }

  /// 保存済み SRT から読む（オフライン再生用）。ファイルが消えていればネット取得に戻る
  Future<void> loadCached(LoopItem item) async {
    _ref.read(subtitleLoadingProvider.notifier).state = true;
    clear();
    try {
      final file = File(item.cachedSubtitlePath!);
      if (!await file.exists()) {
        if (isMounted() && item.videoId != null) await fetch(item);
        return;
      }
      final subs = SubtitleService.parseSrt(await file.readAsString());
      if (!isMounted()) return;
      _ref.read(subtitleDataProvider.notifier).state =
          subs.isNotEmpty ? subs : null;
      // オフライン用に明示保存した字幕は OFF のままだと見えないので自動表示
      if (subs.isNotEmpty &&
          _ref.read(subtitleModeProvider) == SubtitleMode.off) {
        _ref.read(subtitleModeProvider.notifier).state = SubtitleMode.subtitle;
      }
    } catch (_) {
      if (isMounted()) _ref.read(subtitleDataProvider.notifier).state = null;
    } finally {
      if (isMounted()) _ref.read(subtitleLoadingProvider.notifier).state = false;
    }
  }

  /// YouTube から取得する。[language] を渡すとその言語を優先。
  /// 取れたかどうかを item.hasSubtitles に残す（一覧のバッジ用）
  Future<void> fetch(LoopItem item, {String? language}) async {
    final videoId = item.videoId;
    if (videoId == null) return;
    _ref.read(subtitleLoadingProvider.notifier).state = true;
    clear();
    _ref.read(subtitleSubLanguageProvider.notifier).state = null;
    try {
      final result = await SubtitleService.fetchSubtitles(videoId,
          preferredLanguage: language);
      if (!isMounted()) return;
      final subs = result.subs;
      _ref.read(subtitleDataProvider.notifier).state = subs;
      _ref.read(subtitleTracksProvider.notifier).state = result.tracks;
      final hasSubs = subs != null && subs.isNotEmpty;
      if (hasSubs) {
        _ref.read(subtitleLanguageProvider.notifier).state =
            result.selectedLanguage;
        // モードはユーザー選択を維持（デフォルト OFF）
      }
      if (item.hasSubtitles != hasSubs) {
        item.hasSubtitles = hasSubs;
        _ref.read(loopItemsProvider.notifier).update(item);
      }
    } catch (_) {
      // 字幕は無くても再生は続ける
    } finally {
      if (isMounted()) _ref.read(subtitleLoadingProvider.notifier).state = false;
    }
  }

  /// サブ字幕（小さく表示する方）を取得する
  Future<void> fetchSub(SubtitleTrackInfo track) async {
    try {
      final subs = await SubtitleService.fetchTrack(track);
      if (!isMounted()) return;
      _ref.read(subtitleSubDataProvider.notifier).state = subs;
      _ref.read(subtitleSubLanguageProvider.notifier).state = track.languageCode;
    } catch (_) {}
  }

  /// サブ字幕をやめる
  void clearSub() {
    _ref.read(subtitleSubDataProvider.notifier).state = null;
    _ref.read(subtitleSubLanguageProvider.notifier).state = null;
  }
}
