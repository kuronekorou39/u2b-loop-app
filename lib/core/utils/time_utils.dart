class TimeUtils {
  static const nullTime = '--:--.---';
  static const nullTimeShort = '--:--';

  /// Format duration as M:SS.mmm (nullable)
  static String formatNullable(Duration? d) => d == null ? nullTime : format(d);
  static String formatShortNullable(Duration? d) =>
      d == null ? nullTimeShort : formatShort(d);

  /// Format duration as M:SS.mmm
  static String format(Duration d) {
    final total = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
    final minutes = total ~/ 60000;
    final seconds = (total ~/ 1000) % 60;
    final millis = total % 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  /// Format duration as M:SS
  static String formatShort(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// ミリ秒(null可)を M:SS で表示する。null は [nullTimeShort]。
  /// `x != null ? formatShort(Duration(milliseconds: x!)) : '--:--'` が
  /// 14箇所に散っていたのをこれ1つに寄せた。
  static String formatShortMs(int? ms) =>
      ms == null ? nullTimeShort : formatShort(Duration(milliseconds: ms));

  /// 手入力向け: 「1:23.5」「1:23」でも「83.5」（秒）でもよい。全体が時刻でなければ null。
  /// [parse] は文字列の中から時刻らしい部分を拾うので、入力の検証には使わない
  static Duration? parseFlexible(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    if (t.contains(':')) {
      final m = RegExp(r'^(\d+):(\d{1,2})(?:\.(\d{1,3}))?$').firstMatch(t);
      if (m == null) return null;
      final seconds = int.parse(m.group(2)!);
      if (seconds >= 60) return null;
      return Duration(
        minutes: int.parse(m.group(1)!),
        seconds: seconds,
        milliseconds:
            m.group(3) == null ? 0 : int.parse(m.group(3)!.padRight(3, '0')),
      );
    }
    final sec = double.tryParse(t);
    if (sec == null || sec < 0 || !sec.isFinite) return null;
    return Duration(milliseconds: (sec * 1000).round());
  }

  /// Parse M:SS.mmm or M:SS to Duration
  static Duration? parse(String s) {
    final match = RegExp(r'(\d+):(\d{1,2})(?:\.(\d{1,3}))?').firstMatch(s);
    if (match == null) return null;
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final millis = match.group(3) != null
        ? int.parse(match.group(3)!.padRight(3, '0'))
        : 0;
    return Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
  }
}
