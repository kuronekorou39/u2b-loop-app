import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/storage/container_paths.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

void main() {
  const oldRoot =
      '/var/mobile/Containers/Data/Application/DBD860F0-AD63-488A-A0F3-3E9D7CF797E0';
  const root =
      '/var/mobile/Containers/Data/Application/F94CA5E9-FAF2-46CE-AE6B-4033C6D04372';

  test('古い置き場所のパスを今の置き場所に直す', () {
    expect(ContainerPaths.rebase('$oldRoot/Documents/thumbnails/a.jpg', root),
        '$root/Documents/thumbnails/a.jpg');
    expect(
        ContainerPaths.rebase('/private$oldRoot/Library/Caches/v.mp4', root),
        '$root/Library/Caches/v.mp4');
  });

  test('置き場所の外のパスと null はそのまま', () {
    expect(ContainerPaths.rebase('/data/user/0/app/a.jpg', root),
        '/data/user/0/app/a.jpg');
    expect(ContainerPaths.rebase(null, root), isNull);
  });

  test('YouTube の URI は触らず、保存パスだけ直す', () {
    final item = LoopItem(
      id: 'a',
      title: '曲',
      uri: 'https://www.youtube.com/watch?v=x',
      sourceType: SourceTypes.youtube,
      thumbnailPath: '$oldRoot/Documents/thumbnails/a.jpg',
    );
    expect(ContainerPaths.rebaseItem(item, root), isTrue);
    expect(item.thumbnailPath, '$root/Documents/thumbnails/a.jpg');
    expect(item.uri, 'https://www.youtube.com/watch?v=x');
    expect(ContainerPaths.rebaseItem(item, root), isFalse);
  });
}
