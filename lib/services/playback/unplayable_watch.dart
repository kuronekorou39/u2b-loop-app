import 'package:flutter/foundation.dart';

import '../../core/utils/app_errors.dart';
import '../../models/loop_item.dart';
import '../../providers/data_provider.dart';
import '../../providers/playlist_player_provider.dart';

/// YouTube の情報取得（マニフェスト）の結果から、曲が再生できるかを曲に残す。
///
/// 年齢制限・削除など時間をおいても直らない理由（[AppErrors.permanentReason]）で失敗したら
/// 曲に理由を残し、鳴らしているプレイリストではその曲を飛ばす（次回もプレイリストに入れない）。
/// 取れたら残っていた理由を消す（通信エラーなどで一時的に残ったものも、開ければ戻る）。
/// 曲を開く（PlayerLoader）・次の曲の先読み（PlaylistEngine）・まとめて解析で同じものを通す
class UnplayableWatch {
  UnplayableWatch._();

  static Future<T> fetch<T>(
    LoopItemsNotifier items,
    PlaylistPlayerNotifier? playlist,
    LoopItem item,
    Future<T> Function() fetch,
  ) async {
    try {
      final result = await fetch();
      if (item.isUnplayable) await items.setUnplayable(item.id, null);
      return result;
    } catch (e) {
      await note(items, playlist, item, e);
      rethrow;
    }
  }

  /// 失敗 [e] がずっと再生できない理由なら曲に残し、プレイリストでは飛ばす
  static Future<void> note(LoopItemsNotifier items, PlaylistPlayerNotifier? playlist,
      LoopItem item, Object e) async {
    final reason = AppErrors.permanentReason(e);
    if (reason == null) return;
    debugPrint('[Unplayable] ${item.id}: $reason');
    await items.setUnplayable(item.id, reason);
    playlist?.skipItem(item.id);
  }
}
