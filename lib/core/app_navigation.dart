import 'package:flutter/widgets.dart';

/// アプリのいちばん外の Navigator。ミニプレイヤーのように Navigator の外に置いた部品から
/// 画面を開くときに使う
final appNavigatorKey = GlobalKey<NavigatorState>();

/// PlayerScreen が表示中かどうか（PiP 制御用）
bool playerScreenActive = false;

/// [playerScreenActive] を画面の外の部品（下の帯）へ知らせる。
/// initState / dispose の中では作り直しを頼めないので、フレームの後で反映する
final playerScreenShown = ValueNotifier<bool>(false);

void setPlayerScreenActive(bool active) {
  playerScreenActive = active;
  WidgetsBinding.instance
    ..addPostFrameCallback((_) => playerScreenShown.value = playerScreenActive)
    ..ensureVisualUpdate();
}
