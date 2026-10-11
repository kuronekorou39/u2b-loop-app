import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/video_source.dart';
import '../services/youtube_service.dart';
import '../core/storage/app_boxes.dart';

final youtubeServiceProvider = Provider<YouTubeService>((ref) {
  final service = YouTubeService();
  ref.onDispose(service.dispose);
  return service;
});

// --- Dual Player System ---

enum ActiveSlot { a, b }

final activeSlotProvider = StateProvider<ActiveSlot>((ref) => ActiveSlot.a);

/// mpv(media_kit)が動画ファイルの隣にある同名字幕(.srt)を自動読み込みして
/// ネイティブ字幕として表示してしまうのを無効化する。
/// 字幕はアプリ独自のオーバーレイ(KaraokeSubtitle/LyricsOverlay)で描画するため、
/// mpv側の字幕は常に不要。これを切らないとオフライン再生で二重字幕になる。
void _disableNativeSubtitles(Player player) {
  final platform = player.platform;
  if (platform is NativePlayer) {
    // 生成直後でもsetPropertyは初期化完了まで待ってから適用される
    platform.setProperty('sub-auto', 'no');
    platform.setProperty('sub-visibility', 'no');
  }
}

final playerAProvider = Provider<Player>((ref) {
  final player = Player();
  _disableNativeSubtitles(player);
  ref.onDispose(player.dispose);
  return player;
});

final playerBProvider = Provider<Player>((ref) {
  final player = Player();
  _disableNativeSubtitles(player);
  ref.onDispose(player.dispose);
  return player;
});

final controllerAProvider = Provider<VideoController>((ref) {
  return VideoController(ref.watch(playerAProvider));
});

final controllerBProvider = Provider<VideoController>((ref) {
  return VideoController(ref.watch(playerBProvider));
});

// --- Compatibility Layer (active player) ---

final playerProvider = Provider<Player>((ref) {
  final slot = ref.watch(activeSlotProvider);
  return slot == ActiveSlot.a
      ? ref.read(playerAProvider)
      : ref.read(playerBProvider);
});

final videoControllerProvider = Provider<VideoController>((ref) {
  final slot = ref.watch(activeSlotProvider);
  return slot == ActiveSlot.a
      ? ref.read(controllerAProvider)
      : ref.read(controllerBProvider);
});

// --- Preload (inactive) player ---

final preloadPlayerProvider = Provider<Player>((ref) {
  final slot = ref.watch(activeSlotProvider);
  return slot == ActiveSlot.a
      ? ref.read(playerBProvider)
      : ref.read(playerAProvider);
});

final videoSourceProvider = StateProvider<VideoSource?>((ref) => null);

/// ピクチャーインピクチャー表示中かどうか。
///
/// PiPウィンドウにはActivityの内容がそのまま縮小されて映るため、
/// 「今どの画面にいるか」に関係なく**アプリのルートで**映像だけを描く必要がある。
/// 画面ごとに持つと、一覧画面などからPiPに入ったときに
/// その画面がそのままPiPに映ってしまう。
final pipModeProvider = StateProvider<bool>((ref) => false);

final playingProvider = StreamProvider<bool>((ref) {
  return ref.watch(playerProvider).stream.playing;
});

final positionProvider = StreamProvider<Duration>((ref) {
  return ref.watch(playerProvider).stream.position;
});

final durationProvider = StreamProvider<Duration>((ref) {
  return ref.watch(playerProvider).stream.duration;
});

final volumeProvider = StreamProvider<double>((ref) {
  return ref.watch(playerProvider).stream.volume;
});

final rateProvider = StreamProvider<double>((ref) {
  return ref.watch(playerProvider).stream.rate;
});

final seekStepProvider =
    StateNotifierProvider<SeekStepNotifier, int>((ref) => SeekStepNotifier());

class SeekStepNotifier extends StateNotifier<int> {
  static const _key = SettingsKeys.seekStep;

  /// 選べるスキップ秒数。再生画面のメニューと設定画面で共有する
  /// （再生画面のアイコン replay_5/10/30 もこの値に対応している）
  static const options = [5, 10, 30];

  SeekStepNotifier() : super(5) {
    state = AppBoxes.settings.get(_key, defaultValue: 5) as int;
  }

  set value(int v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// プレイリスト遷移のクロスフェード秒数（0=オフ）
final crossfadeProvider =
    StateNotifierProvider<CrossfadeNotifier, int>((ref) => CrossfadeNotifier());

class CrossfadeNotifier extends StateNotifier<int> {
  static const _key = SettingsKeys.crossfadeSeconds;

  /// 選べる秒数。0はオフ
  static const options = [0, 2, 4, 6, 8];

  CrossfadeNotifier() : super(0) {
    state = AppBoxes.settings.get(_key, defaultValue: 0) as int;
  }

  set value(int v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

final flipHorizontalProvider = StateProvider<bool>((ref) => false);
final flipVerticalProvider = StateProvider<bool>((ref) => false);
final previousVolumeProvider = StateProvider<double>((ref) => 100.0);

final waveformDataProvider = StateProvider<List<double>?>((ref) => null);
final waveformLoadingProvider = StateProvider<bool>((ref) => false);
final waveformErrorProvider = StateProvider<String?>((ref) => null);

/// 音量正規化ON/OFF
final volumeNormProvider = StateProvider<bool>((ref) => false);

/// 現在のオーディオ出力デバイス（speaker/headphones/bluetooth）
final audioDeviceProvider = StateProvider<String>((ref) => 'speaker');
