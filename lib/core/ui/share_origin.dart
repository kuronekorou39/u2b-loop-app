import 'dart:ui';

/// 共有シートの吹き出しの位置（画面の中央）。
/// iPad はこれを渡さないと共有シートを開けない。iPhone と Android では使われない
Rect shareOrigin() {
  final view = PlatformDispatcher.instance.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
}
