enum KeyMode { major, minor }

/// 'Gmin' / 'A#maj' 形式のキー文字列と、DJ 用の Camelot 表記・相性判定。
///
/// Hive にはこの文字列のまま保存されるので、表記を変えると既存データが読めなくなる。
class MusicalKey {
  MusicalKey._();

  static const notes = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  /// 設定画面のピッカー用。長調12 + 短調12
  static final List<String> allKeys = [
    for (var i = 0; i < 12; i++) name(i, KeyMode.major),
    for (var i = 0; i < 12; i++) name(i, KeyMode.minor),
  ];

  static String name(int tonic, KeyMode mode) =>
      '${notes[tonic % 12]}${mode == KeyMode.major ? 'maj' : 'min'}';

  /// 不正な文字列は null
  static (int tonic, KeyMode mode)? parse(String? key) {
    if (key == null || key.length < 4) return null;
    final mode = switch (key.substring(key.length - 3)) {
      'maj' => KeyMode.major,
      'min' => KeyMode.minor,
      _ => null,
    };
    if (mode == null) return null;
    final tonic = notes.indexOf(key.substring(0, key.length - 3));
    if (tonic < 0) return null;
    return (tonic, mode);
  }

  /// Camelot 表記（例: Cmaj→8B, Amin→8A）。5度圏で隣り合う番号同士と、
  /// 同じ番号の A/B（平行調）は混ぜても濁りにくい。
  static String? camelot(String? key) {
    final parsed = parse(key);
    if (parsed == null) return null;
    final (tonic, mode) = parsed;
    // 長調は C=8 から5度上がるごとに +1。短調は平行長調（短3度上）と同じ番号
    final majorTonic = mode == KeyMode.major ? tonic : (tonic + 3) % 12;
    var num = (8 + 7 * majorTonic) % 12;
    if (num == 0) num = 12;
    return '$num${mode == KeyMode.major ? 'B' : 'A'}';
  }

  /// 表示用: 'Gmin (6A)'
  static String? display(String? key) {
    final c = camelot(key);
    return c == null ? null : '$key ($c)';
  }

  /// Camelot で同一・平行調・隣接（±1 で同じ A/B）のいずれかなら相性が良い
  static bool isCompatible(String? a, String? b) {
    final ca = camelot(a), cb = camelot(b);
    if (ca == null || cb == null) return false;
    final na = int.parse(ca.substring(0, ca.length - 1));
    final nb = int.parse(cb.substring(0, cb.length - 1));
    if (na == nb) return true;
    final sameMode = ca[ca.length - 1] == cb[cb.length - 1];
    final diff = (na - nb) % 12;
    return sameMode && (diff == 1 || diff == 11);
  }
}
