/// アプリ内で使うIDの生成。
///
/// 以前は `millisecondsSinceEpoch.toString()` が7箇所、
/// `microsecondsSinceEpoch` が2箇所、カウンタ付きの実装が1箇所と3方式が並存していた。
/// ミリ秒だけだと一括追加のように同一ミリ秒で複数生成する場面で衝突する。
class IdGenerator {
  IdGenerator._();

  static int _counter = 0;

  /// 衝突しないID。マイクロ秒＋プロセス内カウンタ。
  static String next() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

  /// 親IDに紐づく子ID（区間など）。親ごとに一意になる。
  static String child(String parentId, String kind) =>
      '${parentId}_$kind${DateTime.now().microsecondsSinceEpoch}';
}
