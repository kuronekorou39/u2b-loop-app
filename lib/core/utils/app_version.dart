/// アプリのバージョン。`1.158.0`（通常版）か `1.158.0-beta.2`（テスト版）。
///
/// 並び: 数字 3 つを先に比べ、同じならテスト版 < 通常版、テスト版どうしは末尾の番号。
/// つまり 1.157.0 < 1.158.0-beta.1 < 1.158.0-beta.2 < 1.158.0
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.core, {this.pre});

  /// major / minor / patch
  final List<int> core;

  /// テスト版の番号（`-beta.2` の 2）。通常版は null
  final int? pre;

  bool get isPrerelease => pre != null;

  /// `v1.2.3` / `1.2.3` / `1.2.3-beta.4`。数字 3 つが読めなければ null
  static AppVersion? tryParse(String text) {
    var s = text.trim();
    if (s.startsWith('v')) s = s.substring(1);
    final dash = s.indexOf('-');
    final coreText = dash < 0 ? s : s.substring(0, dash);
    final parts = coreText.split('.').map(int.tryParse).toList();
    if (parts.length != 3 || parts.contains(null)) return null;
    int? pre;
    if (dash >= 0) {
      // 番号の無い印（-beta）は 0 番として扱う
      final digits = RegExp(r'(\d+)$').firstMatch(s.substring(dash + 1));
      pre = digits == null ? 0 : int.parse(digits.group(1)!);
    }
    return AppVersion(parts.cast<int>(), pre: pre);
  }

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final d = core[i].compareTo(other.core[i]);
      if (d != 0) return d;
    }
    if (pre == null) return other.pre == null ? 0 : 1;
    if (other.pre == null) return -1;
    return pre!.compareTo(other.pre!);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
}
