/// アプリ全体の入力制限値
class AppLimits {
  AppLimits._();

  static const int titleMaxLength = 100;
  static const int memoMaxLength = 500;
  static const int tagNameMaxLength = 30;
  static const int playlistNameMaxLength = 50;
  static const int urlMaxLength = 10000;
  static const int regionNameMaxLength = 20;
  static const int maxTagsPerItem = 20;
  static const int maxRegions = 10;

  /// QRコードに収められるおおよその文字数
  static const int qrMaxLength = 2000;

  /// [text] を [maxLength] 文字までに切る（入力欄を通らずに名前が決まる所で使う。
  /// YouTube のプレイリスト名からタグを作るときなど）。絵文字の途中では切らない
  static String clip(String text, int maxLength) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) return trimmed;
    var end = maxLength;
    final last = trimmed.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return trimmed.substring(0, end).trimRight();
  }
}

