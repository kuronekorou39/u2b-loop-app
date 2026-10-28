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

    test('再生できない理由は YouTube が返す理由から見分ける', () {
      final id = VideoId('qk0ng1HTM-Y');
      String of(String reason) => AppErrors.describe(
          VideoUnplayableException.unplayable(id, reason: reason));
      // 実際に返ってきた理由（年齢制限の動画）
      expect(of('Sign in to confirm your age'), contains('年齢制限'));
      expect(of('この動画は、一部のユーザーに適さない可能性があります。'), contains('年齢制限'));
      expect(of('The uploader has not made this video available in your country'),
          contains('地域制限'));
      expect(of('Join this channel to get access to members-only content like this video'),
          contains('メンバー限定'));
      expect(of('Sign in to confirm you’re not a bot'), contains('ボット'));
      expect(AppErrors.describe(VideoUnplayableException.liveStream(id)),
          contains('ライブ配信'));
      // 知らない理由はそのまま添える。理由が無ければ短く
      expect(of('Something new'), '再生できない動画です（YouTube: Something new）');
      expect(of(''), '再生できない動画です');
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
