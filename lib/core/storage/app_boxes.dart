import 'package:hive/hive.dart';

import '../../models/loop_item.dart';
import '../../models/playlist.dart';
import '../../models/tag.dart';

/// Hive の box 名と型付きアクセサ。
///
/// 以前は `Hive.box<LoopItem>('loop_items')` のようなベタ書きが50箇所以上あり、
/// 名前と型の組み合わせを間違えても実行時まで気づけなかった。
/// 新しい box を足すときはここに追加し、呼び出し側は文字列を書かないこと。
class AppBoxes {
  AppBoxes._();

  static const loopItemsName = 'loop_items';
  static const playlistsName = 'playlists';
  static const tagsName = 'tags';
  static const settingsName = 'settings';

  static Box<LoopItem> get loopItems => Hive.box<LoopItem>(loopItemsName);
  static Box<Playlist> get playlists => Hive.box<Playlist>(playlistsName);
  static Box<Tag> get tags => Hive.box<Tag>(tagsName);
  static Box<dynamic> get settings => Hive.box(settingsName);

  /// アプリ起動時に全boxを開く
  static Future<void> openAll() async {
    await Hive.openBox<LoopItem>(loopItemsName);
    await Hive.openBox<Playlist>(playlistsName);
    await Hive.openBox<Tag>(tagsName);
    await Hive.openBox(settingsName);
  }
}

/// settings box のキー。散らばると綴り間違いに気づけないためここに集約する。
class SettingsKeys {
  SettingsKeys._();

  static const darkMode = 'dark_mode';
  static const seekStep = 'seek_step';
  static const crossfadeSeconds = 'crossfade_seconds';
  static const perfOverlay = 'perf_overlay';
  static const cacheToDocuments = 'cache_to_documents';
  static const loadingAnimation = 'loading_animation';

  // イースターエッグの解放フラグ
  static const eeStats = 'ee_stats';
  static const eeCassette = 'ee_cassette';
  static const eeMatrix = 'ee_matrix';
}
