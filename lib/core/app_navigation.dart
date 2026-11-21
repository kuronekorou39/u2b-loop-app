import 'package:flutter/widgets.dart';

/// アプリのいちばん外の Navigator。ミニプレイヤーのように Navigator の外に置いた部品から
/// 画面を開くときに使う
final appNavigatorKey = GlobalKey<NavigatorState>();

/// PlayerScreen が表示中かどうか（PiP 制御用）
bool playerScreenActive = false;
