import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/video_source.dart';
import '../services/youtube_service.dart';

final youtubeServiceProvider = Provider<YouTubeService>((ref) {
  final service = YouTubeService();
  ref.onDispose(service.dispose);
  return service;
});

// --- Dual Player System ---

enum ActiveSlot { a, b }

final activeSlotProvider = StateProvider<ActiveSlot>((ref) => ActiveSlot.a);

final playerAProvider = Provider<Player>((ref) {
  final player = Player();
  ref.onDispose(player.dispose);
  return player;
});

final playerBProvider = Provider<Player>((ref) {
  final player = Player();
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

final seekStepProvider = StateProvider<int>((ref) => 5);
final flipHorizontalProvider = StateProvider<bool>((ref) => false);
final flipVerticalProvider = StateProvider<bool>((ref) => false);
final previousVolumeProvider = StateProvider<double>((ref) => 100.0);

final waveformDataProvider = StateProvider<List<double>?>((ref) => null);
final waveformLoadingProvider = StateProvider<bool>((ref) => false);
final waveformErrorProvider = StateProvider<String?>((ref) => null);
