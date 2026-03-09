import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
