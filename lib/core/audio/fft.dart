import 'dart:math';
import 'dart:typed_data';

/// 基数2の反復FFT（in-place）。[n] は2の冪であること
class Fft {
  Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Uint32List(n) {
    for (var k = 0; k < n ~/ 2; k++) {
      _cos[k] = cos(2 * pi * k / n);
      _sin[k] = sin(2 * pi * k / n);
    }
    final bits = (log(n) / ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }
  final int n;
  final Float64List _cos, _sin;
  final Uint32List _rev;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = -_sin[k * step];
          final a = start + k;
          final b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}
