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

final playerProvider = Provider<Player>((ref) {
  final player = Player();
  ref.onDispose(player.dispose);
  return player;
});

final videoControllerProvider = Provider<VideoController>((ref) {
  final player = ref.watch(playerProvider);
  return VideoController(player);
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
