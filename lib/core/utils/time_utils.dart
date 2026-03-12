class TimeUtils {
  static const nullTime = '--:--.---';
  static const nullTimeShort = '--:--';

  /// Format duration as M:SS.mmm (nullable)
  static String formatNullable(Duration? d) => d == null ? nullTime : format(d);
  static String formatShortNullable(Duration? d) =>
      d == null ? nullTimeShort : formatShort(d);

  /// Format duration as M:SS.mmm
  static String format(Duration d) {
    final total = d.inMilliseconds.clamp(0, d.inMilliseconds);
    final minutes = total ~/ 60000;
    final seconds = (total ~/ 1000) % 60;
    final millis = total % 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  /// Format duration as M:SS
  static String formatShort(Duration d) {
    final total = d.inSeconds.clamp(0, d.inSeconds);
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
