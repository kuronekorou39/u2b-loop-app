import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/audio/audio_quality.dart';
import '../core/audio/crossfade_curve.dart';
import '../core/audio/transition_effect.dart';
import '../models/video_source.dart';
import '../services/audio_filters.dart';
import '../services/transition_sfx.dart';
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

/// mpv のエラー（media_kit の既定で error 以上だけ届く）を logcat に出す。
/// 音声フィルタ列が作れなかったときは AudioFilters が以後の使用をやめる
void _watchMpvLog(Player player, String name) {
  player.stream.log.listen((log) {
    debugPrint('[mpv $name] ${log.level} ${log.prefix}: ${log.text}');
    AudioFilters.noteLog(log);
  });
}

final playerAProvider = Provider<Player>((ref) {
  final player = Player();
  _disableNativeSubtitles(player);
  _watchMpvLog(player, 'A');
  ref.onDispose(player.dispose);
  return player;
});

final playerBProvider = Provider<Player>((ref) {
  final player = Player();
  _disableNativeSubtitles(player);
  _watchMpvLog(player, 'B');
  ref.onDispose(player.dispose);
  return player;
});

/// 効果音用の 3 枚目のプレイヤー（映像なし）。
/// 切り替えの演出で効果音を使うときに初めて作られる（使わない人にはコストが無い）
final sfxPlayerProvider = Provider<Player>((ref) {
  final player = Player();
  _watchMpvLog(player, 'SFX');
  ref.onDispose(player.dispose);
  return player;
});

final transitionSfxProvider =
    Provider<TransitionSfx>((ref) => TransitionSfx(ref.watch(sfxPlayerProvider)));

final controllerAProvider = Provider<VideoController>((ref) {
  return VideoController(ref.watch(playerAProvider));
});

final controllerBProvider = Provider<VideoController>((ref) {
  return VideoController(ref.watch(playerBProvider));
});

/// プレイヤーごとの「いま鳴っている音声の素性」。
/// 曲を開く側（PlaylistEngine.prepare / PlayerLoader）が開くたびに書き、
/// 高音質の音声が本当に付いたら上書きする。画面は [activeAudioQualityProvider] を見る
final audioQualityProvider =
    StateNotifierProvider<AudioQualityNotifier, Map<Player, AudioQuality>>(
        (ref) => AudioQualityNotifier());

class AudioQualityNotifier extends StateNotifier<Map<Player, AudioQuality>> {
  AudioQualityNotifier() : super(const {});

  void set(Player player, AudioQuality quality) {
    state = {...state, player: quality};
  }
}

/// アクティブなプレイヤーの音声の素性（まだ開いていなければ null）
final activeAudioQualityProvider = Provider<AudioQuality?>((ref) {
  return ref.watch(audioQualityProvider)[ref.watch(playerProvider)];
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

// 再生状態の配信。曲が替わると playerProvider が裏のプレイヤーに切り替わるが、
// media_kit のストリームは値が変わったときしか流れないので、切り替え直後は
// 前のプレイヤーの値（曲末でフェードアウトした音量 0 など）が残って見えていた。
// 最初に今の値を流してから購読する
Stream<T> _currentThenChanges<T>(T current, Stream<T> changes) async* {
  yield current;
  yield* changes;
}

final playingProvider = StreamProvider<bool>((ref) {
  final p = ref.watch(playerProvider);
  return _currentThenChanges(p.state.playing, p.stream.playing);
});

final positionProvider = StreamProvider<Duration>((ref) {
  final p = ref.watch(playerProvider);
  return _currentThenChanges(p.state.position, p.stream.position);
});

final durationProvider = StreamProvider<Duration>((ref) {
  final p = ref.watch(playerProvider);
  return _currentThenChanges(p.state.duration, p.stream.duration);
});

final volumeProvider = StreamProvider<double>((ref) {
  final p = ref.watch(playerProvider);
  return _currentThenChanges(p.state.volume, p.stream.volume);
});

final rateProvider = StreamProvider<double>((ref) {
  final p = ref.watch(playerProvider);
  return _currentThenChanges(p.state.rate, p.stream.rate);
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

/// プレイリスト遷移のクロスフェードの長さ（拍数。0=オフ）。
/// DJ は秒ではなく小節で数える（4 拍 = 1 小節）。秒数は曲の BPM から PlaylistEngine が出す
final crossfadeProvider =
    StateNotifierProvider<CrossfadeNotifier, int>((ref) => CrossfadeNotifier());

class CrossfadeNotifier extends StateNotifier<int> {
  static const _key = SettingsKeys.crossfadeBeats;

  /// 選べる拍数。0はオフ。4 拍 = 1 小節
  static const options = [0, 4, 8, 16, 32];

  /// v1.94 までの秒数設定からの移行先（オンだった人は 8 拍 = 2 小節）
  static const migratedBeats = 8;

  CrossfadeNotifier() : super(0) {
    final box = AppBoxes.settings;
    final beats = box.get(_key) as int?;
    if (beats != null) {
      state = beats;
    } else {
      final seconds = box.get(SettingsKeys.crossfadeSeconds, defaultValue: 0) as int;
      state = seconds > 0 ? migratedBeats : 0;
    }
  }

  set value(int v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// YouTube を音声専用ストリーム（高音質）で鳴らすか（既定オン）。
/// 一体型ストリームの音声は 96kbps しかない。仕組みは HqAudio を参照
final hqAudioProvider =
    StateNotifierProvider<HqAudioNotifier, bool>((ref) => HqAudioNotifier());

class HqAudioNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.hqAudio;

  HqAudioNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// クロスフェード中に次曲の速度を前曲のテンポへ寄せるか（既定オン）。
/// クロスフェードがオフのときは効かない
final tempoMatchProvider =
    StateNotifierProvider<TempoMatchNotifier, bool>((ref) => TempoMatchNotifier());

class TempoMatchNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.tempoMatch;

  TempoMatchNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// クロスフェードで次曲のドロップ（音量が上がる点）が切り替わりに来るよう開始位置をずらし、
/// 出ていく曲はアウトロの落ち込みで切るか（既定オン）。クロスフェードがオフのときは効かない
final mixPointAlignProvider =
    StateNotifierProvider<MixPointAlignNotifier, bool>((ref) => MixPointAlignNotifier());

class MixPointAlignNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.mixPointAlign;

  MixPointAlignNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// クロスフェードの音量曲線（つなぎ方）。既定は等パワー
final crossfadeCurveProvider =
    StateNotifierProvider<CrossfadeCurveNotifier, CrossfadeCurve>(
        (ref) => CrossfadeCurveNotifier());

class CrossfadeCurveNotifier extends StateNotifier<CrossfadeCurve> {
  static const _key = SettingsKeys.crossfadeCurve;

  CrossfadeCurveNotifier() : super(CrossfadeCurve.defaultCurve) {
    state = CrossfadeCurve.fromName(AppBoxes.settings.get(_key) as String?);
  }

  set value(CrossfadeCurve v) {
    state = v;
    AppBoxes.settings.put(_key, v.name);
  }
}

/// 拍合わせ: 交差を始めるとき次曲の開始位置を ±半拍ずらして拍の頭を揃え、
/// テンポが揃っていれば交差中も速度を微調整して合わせ続ける（既定オン）。
/// 両方の曲に拍の格子（解析結果）があるときだけ効く
final beatMatchProvider =
    StateNotifierProvider<BeatMatchNotifier, bool>((ref) => BeatMatchNotifier());

class BeatMatchNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.beatMatch;

  BeatMatchNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// ベーススワップ: 交差中は入る曲の低音を切って重ね、途中で出る曲と入れ替える（既定オン）
final bassSwapProvider =
    StateNotifierProvider<BassSwapNotifier, bool>((ref) => BassSwapNotifier());

class BassSwapNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.bassSwap;

  BassSwapNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// 切り替わりの演出（フィルタースイープ / ライザーなど）。既定はフィルタースイープ
final transitionEffectProvider =
    StateNotifierProvider<TransitionEffectNotifier, TransitionEffect>(
        (ref) => TransitionEffectNotifier());

class TransitionEffectNotifier extends StateNotifier<TransitionEffect> {
  static const _key = SettingsKeys.transitionEffect;

  TransitionEffectNotifier() : super(TransitionEffect.defaultEffect) {
    state = TransitionEffect.fromName(AppBoxes.settings.get(_key) as String?);
  }

  set value(TransitionEffect v) {
    state = v;
    AppBoxes.settings.put(_key, v.name);
  }
}

/// おまかせ: 2 曲の解析結果からつなぎ方（長さ・曲線・低音・演出・合わせるか）を自動で選ぶ（既定オン）。
/// オフのときは手動の設定（つなぎ方 / テンポ合わせ / 拍合わせ / ベーススワップ / 演出）が効く。
/// クロスフェードのオン/オフと「ドロップに合わせる」「効果音の音量」はどちらでも手動
final autoMixProvider =
    StateNotifierProvider<AutoMixNotifier, bool>((ref) => AutoMixNotifier());

class AutoMixNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.autoMix;

  AutoMixNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// 切り替えの効果音の音量（曲との差 dB）。既定は曲より 6dB 小さい
final sfxLevelProvider =
    StateNotifierProvider<SfxLevelNotifier, int>((ref) => SfxLevelNotifier());

class SfxLevelNotifier extends StateNotifier<int> {
  static const _key = SettingsKeys.sfxLevelDb;

  static const options = [-12, -6, 0];
  static const defaultDb = -6;

  static String label(int db) => switch (db) {
        <= -12 => '控えめ',
        < 0 => 'ふつう',
        _ => '大きめ',
      };

  /// 「曲より 6dB 小さい」のような説明
  static String describe(int db) => db >= 0 ? '曲と同じ大きさ' : '曲より ${-db}dB 小さい';

  SfxLevelNotifier() : super(defaultDb) {
    state = AppBoxes.settings.get(_key, defaultValue: defaultDb) as int;
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

/// 音量正規化（曲ごとに測った大きさで音量を揃える。Loudness）。既定オフ、保存する
final volumeNormProvider =
    StateNotifierProvider<VolumeNormNotifier, bool>((ref) => VolumeNormNotifier());

class VolumeNormNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.volumeNorm;

  VolumeNormNotifier() : super(false) {
    state = AppBoxes.settings.get(_key, defaultValue: false) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

/// 現在のオーディオ出力デバイス（speaker/headphones/bluetooth）
final audioDeviceProvider = StateProvider<String>((ref) => 'speaker');
