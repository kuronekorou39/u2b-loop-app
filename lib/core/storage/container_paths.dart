import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/loop_item.dart';
import 'app_boxes.dart';

/// iOS はアプリを更新するとデータの置き場所のフォルダ名（UUID）が変わる。
/// 中身は引き継がれるが、保存しておいた絶対パスは古いままで開けなくなるので、
/// 起動時に今の置き場所へ書き換える
class ContainerPaths {
  ContainerPaths._();

  static final _root = RegExp(
      r'^(?:/private)?/var/mobile/Containers/Data/Application/[0-9A-Fa-f-]+(?=/)');

  /// [path] が iOS のアプリの置き場所の中なら、先頭を [currentRoot] に置き換える
  static String? rebase(String? path, String currentRoot) =>
      path?.replaceFirst(_root, currentRoot);

  /// [item] の保存パスを直す。変わったら true
  static bool rebaseItem(LoopItem item, String currentRoot) {
    final thumbnail = rebase(item.thumbnailPath, currentRoot);
    final video = rebase(item.cachedVideoPath, currentRoot);
    final subtitle = rebase(item.cachedSubtitlePath, currentRoot);
    final uri = item.isLocal ? rebase(item.uri, currentRoot)! : item.uri;
    final changed = thumbnail != item.thumbnailPath ||
        video != item.cachedVideoPath ||
        subtitle != item.cachedSubtitlePath ||
        uri != item.uri;
    if (!changed) return false;
    item
      ..thumbnailPath = thumbnail
      ..cachedVideoPath = video
      ..cachedSubtitlePath = subtitle
      ..uri = uri;
    return true;
  }

  /// 起動時に一度呼ぶ。失敗しても起動は止めない
  static Future<void> repair() async {
    if (!Platform.isIOS) return;
    try {
      final root = (await getApplicationDocumentsDirectory()).parent.path;
      final box = AppBoxes.loopItems;
      final changed = <dynamic, LoopItem>{
        for (final key in box.keys)
          if (box.get(key) case final item? when rebaseItem(item, root))
            key: item,
      };
      if (changed.isNotEmpty) await box.putAll(changed);
    } catch (_) {}
  }
}
