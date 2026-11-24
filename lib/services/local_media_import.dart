import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// ローカルの動画・音楽を選んで、アプリで使い続けられる場所に置く。
///
/// - Android: 1 つの選択画面で動画も音楽も選べる（content:// のまま使う）
/// - iOS: 写真ライブラリ（動画）と「ファイル」（動画・音楽）の 2 つの入口がある。
///   どちらも選んだファイルは一時フォルダに複製されて OS に消されることがあるので、
///   Documents/local に移してから登録する
class LocalMediaImport {
  LocalMediaImport._();

  static const _dirName = 'local';

  /// 「ファイル」から選べる形式（mpv で再生でき、iOS の AVFoundation で波形も取れるもの）
  static const extensions = [
    'mp4', 'm4v', 'mov', 'mkv', 'webm',
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus',
  ];

  /// 選ぶ画面を開く。[fromPhotos] は iOS の写真ライブラリ（動画だけ）
  static Future<FilePickerResult?> pick({
    required bool fromPhotos,
    void Function(FilePickerStatus)? onFileLoading,
  }) {
    return FilePicker.platform.pickFiles(
      type: fromPhotos ? FileType.video : FileType.custom,
      allowedExtensions: fromPhotos ? null : extensions,
      allowMultiple: true,
      onFileLoading: onFileLoading,
    );
  }

  /// 選んだファイルを残る場所に移し、登録に使うパスを返す（iOS 以外はそのまま）
  static Future<String> persist(String path, String name) async {
    if (!Platform.isIOS) return path;
    final source = File(path);
    if (!await source.exists()) return path;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/${uniqueName(name, DateTime.now())}');
    try {
      return (await source.rename(target.path)).path;
    } on FileSystemException {
      // 別のボリュームなどで移せないときは複製する
      return (await source.copy(target.path)).path;
    }
  }

  /// 同じ名前のファイルを何度選んでもぶつからない名前（拡張子は残す。AVFoundation が形式を見分けるため）
  static String uniqueName(String name, DateTime now) {
    final safe = name.replaceAll(RegExp(r'[/\\:]'), '_');
    return '${now.microsecondsSinceEpoch}_$safe';
  }
}
