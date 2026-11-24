/// 再生中なのに位置が進まなくなったことを見つける。
///
/// iOS では次の曲へ移った直後に、再生中のまま止まることがある
/// （一時停止して再開すると動き出す）
class PlaybackStallWatch {
  static const stallAfter = Duration(milliseconds: 1500);

  Duration? _position;
  DateTime? _since;

  /// 定期的に呼ぶ。[stallAfter] の間 [position] が動いていなければ true。
  /// [active] は「進むはずの状態か」（再生中で、読み込み待ちでも終端でもない）
  bool shouldKick({
    required Duration position,
    required bool active,
    required DateTime now,
  }) {
    final since = _since;
    if (!active || since == null || position != _position) {
      _position = position;
      _since = now;
      return false;
    }
    if (now.difference(since) < stallAfter) return false;
    _since = now;
    return true;
  }
}
