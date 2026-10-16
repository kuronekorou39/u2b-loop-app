import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 出る曲のプレイヤーにかける DJ のトリックの土台（mpv のプロパティ操作）。
///
/// - ブレーキ: 速度を 1 → 0 へ落とす間、音程も一緒に落とす（`audio-pitch-correction=no`。
///   既定の scaletempo2 は音程を保つので、それではレコードが止まる音にならない）
/// - ループロール: mpv の `ab-loop-a` / `ab-loop-b` で短いループを刻む。アプリ側の
///   100ms タイマー（LoopNotifier）では 1/8 拍（60ms 程度）のループは刻めないが、mpv は
///   hr-seek で精密に回してくれる
///
/// 触ったプレイヤーは覚えておき、[reset] で初期状態に戻す（プレイヤーは 2 枚を使い回すので、
/// 戻し忘れると次の曲が音程の狂った速度変更や短いループのままになる）
class DeckTricks {
  DeckTricks._();

  static final _touched = <int>{};

  static Future<void> setPitchCorrection(Player player, bool on) async {
    _touched.add(player.hashCode);
    await _set(player, 'audio-pitch-correction', on ? 'yes' : 'no');
  }

  /// [aMs] 〜 [bMs]（媒体のミリ秒）を繰り返す。再生位置が b を越えたら mpv が a へ戻す
  /// （設定した時点で b を越えていればすぐ戻る）
  static Future<void> setAbLoop(Player player, double aMs, double bMs) async {
    _touched.add(player.hashCode);
    await _set(player, 'ab-loop-a', (aMs / 1000).toStringAsFixed(3));
    await _set(player, 'ab-loop-b', (bMs / 1000).toStringAsFixed(3));
  }

  static Future<void> clearAbLoop(Player player) async {
    await _set(player, 'ab-loop-a', 'no');
    await _set(player, 'ab-loop-b', 'no');
  }

  /// 初期状態（音程補正あり・ループ無し）へ。触っていなければ何もしない
  static Future<void> reset(Player player) async {
    if (!_touched.remove(player.hashCode)) return;
    await _set(player, 'audio-pitch-correction', 'yes');
    await clearAbLoop(player);
  }

  static Future<void> _set(Player player, String name, String value) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(name, value);
    } catch (e) {
      debugPrint('[DeckTricks] $name=$value の設定に失敗: $e');
    }
  }
}
