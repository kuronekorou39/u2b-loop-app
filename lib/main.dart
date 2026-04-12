import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'models/loop_item.dart';
import 'models/playlist.dart' as app;
import 'models/tag.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Hive
  await Hive.initFlutter();
  Hive.registerAdapter(LoopItemAdapter());
  Hive.registerAdapter(app.PlaylistAdapter());
  Hive.registerAdapter(TagAdapter());
  await Hive.openBox<LoopItem>('loop_items');
  await Hive.openBox<app.Playlist>('playlists');
  await Hive.openBox<Tag>('tags');
  await Hive.openBox('settings');

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ProviderScope(child: App()));
}
