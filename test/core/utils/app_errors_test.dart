import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/app_errors.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// 例外 → 人に見せる文
void main() {
  group('AppErrors.describe', () {
    test('通信系は日本語の説明にする', () {
      expect(AppErrors.describe(const SocketException('Failed host lookup')),
          'ネットワークに接続できません');
      expect(AppErrors.describe(TimeoutException('x')), contains('応答がありません'));
    });

    test('YouTube の非公開・制限は原因が分かる文にする', () {
      expect(AppErrors.describe(VideoUnavailableException('abc')),
          contains('見つかりません'));
      expect(AppErrors.describe(VideoUnplayableException('abc')),
          contains('再生できない'));
      expect(
          AppErrors.describe(VideoRequiresPurchaseException.preview(
              VideoId('dQw4w9WgXcQ'), VideoId('dQw4w9WgXcQ'))),
          contains('購入'));
    });

    test('それ以外は型名の前置きを外す', () {
      expect(AppErrors.describe(Exception('再生可能なストリームがありません')),
          '再生可能なストリームがありません');
      expect(AppErrors.describe(StateError('bad')), 'bad');
      expect(AppErrors.describe('そのまま'), 'そのまま');
    });

    test('長すぎる文は切る', () {
      final long = 'a' * 500;
      final text = AppErrors.describe(Exception(long));
      expect(text.length, lessThan(200));
      expect(text, endsWith('…'));
    });
  });

  group('LoopItem の BPM・キー表記', () {
    test('「120 BPM」とキーを順に並べる。無いものは出さない', () {
      final item = LoopItem(
          id: 'i', title: 't', uri: 'u', sourceType: 'local',
          bpm: 119.6, musicalKey: 'Am');
      expect(item.bpmLabel, '120 BPM');
      expect(item.musicInfoParts, ['120 BPM', 'Am']);
      final none = LoopItem(id: 'j', title: 't', uri: 'u', sourceType: 'local');
      expect(none.bpmLabel, isNull);
      expect(none.musicInfoParts, isEmpty);
    });
  });
}
