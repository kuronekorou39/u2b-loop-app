/// YouTube 側に制限されないよう、続けて取りに行くときに空ける間隔。
/// 回数が増えるほど長くなり、しばらく空くと最初に戻る。
/// 決まった増え方なので、これから何件取るかが分かれば待ち時間の合計も先に計算できる
class RequestPacing {
  RequestPacing({DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _last = (now ?? DateTime.now)();

  static const resetAfter = Duration(seconds: 30);
  static const baseMs = 300;
  static const stepMs = 200;
  static const requestsPerStep = 10;
  static const maxMs = 3000;

  final DateTime Function() _now;
  DateTime _last;
  int _count = 0;

  /// [count] 回目のあとに空ける間隔
  static int delayMsFor(int count) =>
      (baseMs + (count ~/ requestsPerStep) * stepMs).clamp(baseMs, maxMs);

  bool get _expired => _now().difference(_last) > resetAfter;

  /// 次に空ける間隔（1 回ぶん数える）
  Duration next() {
    if (_expired) _count = 0;
    _last = _now();
    _count++;
    return Duration(milliseconds: delayMsFor(_count));
  }

  /// これから [requests] 回取りに行くときの間隔の合計（数えは進めない）
  Duration upcoming(int requests) {
    final start = _expired ? 0 : _count;
    var ms = 0;
    for (var i = 1; i <= requests; i++) {
      ms += delayMsFor(start + i);
    }
    return Duration(milliseconds: ms);
  }
}
