import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/loop_item.dart';
import '../models/playlist_track.dart';
import '../services/cache_service.dart';
import '../services/youtube_service.dart';
import 'loop_provider.dart';
import 'player_provider.dart';
import 'playlist_player_provider.dart';

final playlistEngineProvider =
    Provider<PlaylistEngine>((ref) => PlaylistEngine(ref));

/// 次トラックへ進めるかの判定結果。
enum AdvanceReadiness {
  /// 同一アイテムの別区間 → シークだけで移れる（ロード不要）
  sameItem,

  /// 別アイテムだがプリロード済み → スワップで即座に移れる
  preloaded,

  /// 未準備 → ロードが必要（呼び出し側がローディング表示 or ループ継続を選ぶ）
  notReady,

  /// 次トラックが無い（プレイリスト終端かつリピートなし）
  none,
}

/// プレイリスト遷移の「機構」を1箇所に集約したもの。
///
/// 以前は PlayerScreen 用とミニプレイヤー用に遷移処理が2重実装されており、
/// 「旧プレイヤーを止め忘れて二重再生」「前曲の再生速度が残る」
/// 「オフライン保存済み動画がミニプレイヤーで再生できず次曲に進めない」など、
/// 片方にだけ修正が入る形の不具合が繰り返し発生していた。
///
/// 画面の有無で変わらない部分（URL解決・プリロード・スロット入替・遷移可否判定）を
/// ここに置き、画面固有の演出（ローディング表示・波形・字幕・フェード）だけを
/// 呼び出し側に残す。
class PlaylistEngine {
  PlaylistEngine(this._ref);

  final Ref _ref;

  /// 現在のアクティブプレイヤー（再生中の側）。
  Player get activePlayer => _ref.read(playerProvider);

  /// 現在のプリロード用プレイヤー（非アクティブ側）。
  Player get preloadPlayer => _ref.read(preloadPlayerProvider);

  // --- URL解決 ---

  /// 再生対象のURIを解決する。
  /// オフライン保存済みならローカルファイルを優先し、通信を一切行わない。
  /// YouTubeで解決できない場合は null（呼び出し側が次の手段を選ぶ）。
  Future<String?> resolvePlayableUri(LoopItem item) async {
    final cached = CacheService.offlineVideoPath(item);
    if (cached != null) return cached;
    if (!item.isYouTube || item.videoId == null) {
      return item.uri.isEmpty ? null : item.uri;
    }
    try {
      return await _ref.read(youtubeServiceProvider).resolveStreamUrl(item.videoId!);
    } catch (e) {
      debugPrint('[PlaylistEngine] URL解決に失敗: $e');
      return null;
    }
  }

  // --- プリロード / ロードの共通機構 ---

  /// [player] に [track] を読み込んで再生準備を整える。
  ///
  /// - オフライン保存済みならローカルファイルを使う（通信なし・即時）
  /// - duration が取れない場合は無音で短く再生してメタデータを確定させる
  ///   （duration=0 のままだとループ監視も終端検知も働かない）
  /// - 開始位置へシークし、**毎回**速度を設定する
  ///   （プレイヤーを2枚使い回す設計のため、設定しないと前曲の速度が残る）
  ///
  /// [isStale] が true を返した時点で処理を打ち切る（曲を素早く切り替えた際のレース対策）。
  /// 戻り値は YouTube のマニフェスト（波形の先行生成に再利用するため）。
  /// キャッシュ再生・ローカルファイルの場合は null。
  Future<StreamManifest?> prepare(
    Player player,
    PlaylistTrack track, {
    bool Function()? isStale,
    bool waitForMetadata = true,
  }) async {
    bool stale() => isStale?.call() ?? false;
    final item = track.item;

    StreamManifest? manifest;
    final cached = CacheService.offlineVideoPath(item);
    if (cached != null) {
      await player.open(Media(cached), play: false);
    } else if (item.isYouTube && item.videoId != null) {
      final ytService = _ref.read(youtubeServiceProvider);
      manifest = await ytService.getManifestWithFallback(item.videoId!);
      if (stale()) return null;
      await player.open(Media(YouTubeService.pickStreamUrl(manifest)), play: false);
    } else {
      await player.open(Media(item.uri), play: false);
    }
    if (stale()) return manifest;

    if (waitForMetadata && player.state.duration == Duration.zero) {
      final restoreVolume = _ref.read(playerProvider).state.volume;
      await player.setVolume(0);
      await player.play();
      for (var i = 0;
          i < 30 && player.state.duration == Duration.zero && !stale();
          i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await player.pause();
      await player.setVolume(restoreVolume);
      if (stale()) return manifest;
    }

    await player.seek(Duration(milliseconds: track.startMs ?? 0));
    await player.setRate(item.speed);
    return manifest;
  }

  // --- スロット入替 ---

  /// アクティブスロットを入れ替え、プリロード済みプレイヤーの再生を開始する。
  ///
  /// 旧プレイヤーは**必ず** stop する。省くと、次のプリロードが旧プレイヤーを
  /// 再openするまで（次曲が無ければ永久に）二重再生になる。
  /// completed購読の張り替えは activeSlotProvider の変化に追従して
  /// LoopNotifier が自動で行うため、ここでは呼ばない。
  ///
  /// 戻り値は新しくアクティブになったプレイヤー。
  Player swapSlots() {
    final oldPlayer = _ref.read(playerProvider);
    final newSlot =
        _ref.read(activeSlotProvider) == ActiveSlot.a ? ActiveSlot.b : ActiveSlot.a;
    _ref.read(activeSlotProvider.notifier).state = newSlot;

    // プロバイダ経由だと同一フレーム内で更新が反映されない場合があるため直接参照する
    final newPlayer = newSlot == ActiveSlot.a
        ? _ref.read(playerAProvider)
        : _ref.read(playerBProvider);

    oldPlayer.stop();
    newPlayer.play();
    return newPlayer;
  }

  // --- 区間の適用 ---

  /// トラックのAB区間を loopProvider に反映する。区間なしならループ解除。
  void applyRegion(PlaylistTrack track) {
    final notifier = _ref.read(loopProvider.notifier);
    if (!track.hasRegion) {
      notifier.reset();
      return;
    }
    notifier.setPointA(
        track.startMs != null ? Duration(milliseconds: track.startMs!) : null);
    notifier.setPointB(
        track.endMs != null ? Duration(milliseconds: track.endMs!) : null);
    if (!_ref.read(loopProvider).enabled) notifier.toggleEnabled();
  }

  // --- 遷移可否の判定 ---

  /// 次トラックへ進めるかを判定する。
  ///
  /// [preloadedIndex] はプリロード済みトラックのインデックス（未プリロードなら null）。
  /// [pendingJumpIndex] は手動選択の予約（次の自動遷移でそこへ跳ぶ）。
  AdvanceReadiness readiness({
    int? preloadedIndex,
    int? pendingJumpIndex,
  }) {
    final ps = _ref.read(playlistPlayerProvider);
    final nextIdx = ps.peekNextTrackIndex();
    if (nextIdx == null && pendingJumpIndex == null) return AdvanceReadiness.none;

    final current = ps.currentTrack;
    if (nextIdx != null &&
        current != null &&
        ps.tracks[nextIdx].isSameItem(current)) {
      return AdvanceReadiness.sameItem;
    }
    if (preloadedIndex != null &&
        (pendingJumpIndex == preloadedIndex || nextIdx == preloadedIndex)) {
      return AdvanceReadiness.preloaded;
    }
    return AdvanceReadiness.notReady;
  }
}
