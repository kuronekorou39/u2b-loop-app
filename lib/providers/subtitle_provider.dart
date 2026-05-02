import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/subtitle_service.dart';

/// 現在の字幕データ
final subtitleDataProvider =
    StateProvider<List<SubtitleEntry>?>((ref) => null);

/// 字幕読込中
final subtitleLoadingProvider = StateProvider<bool>((ref) => false);

/// 字幕表示ON/OFF
final subtitleVisibleProvider = StateProvider<bool>((ref) => false);
