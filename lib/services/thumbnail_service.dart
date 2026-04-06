import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class ThumbnailService {
  Future<String?> save(String id, String? thumbnailUrl) async {
    if (thumbnailUrl == null) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${dir.path}/thumbnails');
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      final file = File('${thumbDir.path}/$id.jpg');

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(thumbnailUrl));
        final response = await request.close();
        if (response.statusCode != 200) return null;
        final bytes = await response.fold<List<int>>(
            [], (prev, chunk) => prev..addAll(chunk));
        await file.writeAsBytes(bytes);
        return file.path;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// ローカル動画ファイルからサムネイルを生成して保存
  Future<String?> generateFromVideo(String id, String videoPath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${dir.path}/thumbnails');
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      final outPath = '${thumbDir.path}/$id.jpg';

      final Uint8List? bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 75,
      );

      if (bytes == null || bytes.isEmpty) return null;
      await File(outPath).writeAsBytes(bytes);
      return outPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String id) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/thumbnails/$id.jpg');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
