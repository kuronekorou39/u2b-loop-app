import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import 'persisted_setting.dart';

/// パフォーマンスオーバーレイ（FPS・描画負荷）の表示設定。設定 > デバッグ
final perfOverlayProvider = StateNotifierProvider<PersistedBool, bool>(
    (ref) => PersistedBool(SettingsKeys.perfOverlay, false));
