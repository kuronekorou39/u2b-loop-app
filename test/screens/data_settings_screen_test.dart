import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/ui/app_snack_bar.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/settings/data_settings_screen.dart';
import 'package:u2b_loop_app/widgets/settings/backup_export_dialog.dart';
import 'package:u2b_loop_app/widgets/settings/settings_parts.dart';

/// 端末の保存画面の代わり。開かれた回数と、渡された中身を覚える
class _FakePicker extends FilePicker {
  int saves = 0;
  Uint8List? bytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saves++;
    this.bytes = bytes;
    return '/picked/$fileName';
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('u2b_data_settings_test');
    Hive.init(tempDir.path);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(PlaylistAdapter());
    Hive.registerAdapter(TagAdapter());
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Playlist>(AppBoxes.playlistsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: DataSettingsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openExport(WidgetTester tester) async {
    await tester.tap(find.text('バックアップを書き出す'));
    await tester.pumpAndSettle();
  }

  Finder inDialog(String text) => find.descendant(
      of: find.byType(BackupExportDialog), matching: find.text(text));

  testWidgets('書き出すと、まず保存するものとしないものを出す。キャンセルならファイルの画面を開かない',
      (tester) async {
    final picker = _FakePicker();
    FilePicker.platform = picker;
    await AppBoxes.loopItems.put(
        'a',
        LoopItem(
            id: 'a',
            title: '曲 A',
            uri: 'https://youtu.be/aaa',
            sourceType: SourceTypes.youtube,
            videoId: 'aaa'));
    addTearDown(AppBoxes.loopItems.clear);

    await pumpAt(tester, const Size(412, 915));
    await openExport(tester);
    for (final label in [
      '保存する',
      '保存しない',
      ...BackupExportDialog.savedLabels,
      ...BackupExportDialog.notSavedLabels,
    ]) {
      expect(inDialog(label), findsOneWidget, reason: label);
    }
    expect(picker.saves, 0);

    await tester.tap(inDialog('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byType(BackupExportDialog), findsNothing);
    expect(picker.saves, 0);

    await openExport(tester);
    await tester.tap(inDialog('書き出す'));
    await tester.pumpAndSettle();
    expect(find.byType(BackupExportDialog), findsNothing);
    expect(picker.saves, 1);
    final json = jsonDecode(utf8.decode(picker.bytes!)) as Map<String, dynamic>;
    expect((json['items'] as List).single['title'], '曲 A');

    AppToast.instance.hide();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('小さい縦の電話でもポップアップは画面に収まる', (tester) async {
    FilePicker.platform = _FakePicker();
    await pumpAt(tester, const Size(360, 640));
    await openExport(tester);

    expect(tester.takeException(), isNull);
    expect(tester.getRect(inDialog('保存しない')).top,
        greaterThan(tester.getRect(inDialog('保存する')).bottom));
    expect(tester.getRect(inDialog('書き出す')).bottom, lessThan(640));
  });

  testWidgets('低い横画面は 2 列で、ボタンは見出しの行。スクロールせずに収まる', (tester) async {
    FilePicker.platform = _FakePicker();
    for (final size in const [Size(915, 412), Size(800, 360), Size(640, 360)]) {
      await pumpAt(tester, size);
      await openExport(tester);

      expect(tester.takeException(), isNull, reason: '$size');
      final saved = tester.getRect(inDialog('保存する'));
      final notSaved = tester.getRect(inDialog('保存しない'));
      expect(notSaved.left, greaterThan(saved.right), reason: '$size');
      expect(notSaved.top, saved.top, reason: '$size');
      final title = tester.getRect(inDialog('バックアップの中身'));
      final button = tester.getRect(inDialog('書き出す'));
      expect(button.left, greaterThan(title.right), reason: '$size');
      expect(button.center.dy, closeTo(title.center.dy, 2), reason: '$size');
      final scroll = tester.state<ScrollableState>(find.descendant(
          of: find.byType(BackupExportDialog),
          matching: find.byType(Scrollable)));
      expect(scroll.position.maxScrollExtent, 0, reason: '$size');

      await tester.tap(inDialog('キャンセル'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('使用量の行は、どの群でも 1 行目で同じアイコン', (tester) async {
    await pumpAt(tester, const Size(412, 1400));
    for (final group in const ['オフライン動画', '自動キャッシュ', '波形']) {
      final first = tester.widget<SettingsRow>(find
          .descendant(
            of: find.byWidgetPredicate(
                (w) => w is SettingsGroup && w.title == group),
            matching: find.byType(SettingsRow),
          )
          .first);
      expect(first.title, '使用量', reason: group);
      expect(first.icon, Icons.data_usage, reason: group);
    }
  });
}
