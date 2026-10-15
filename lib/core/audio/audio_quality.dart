/// いま鳴っている音声の素性（再生画面に出す）。
///
/// YouTube の高音質（HqAudio）は落とせなければ黙って一体型に戻るので、
/// どちらで鳴っているかを画面で分かるようにしておく
enum AudioQualityKind { hq, standard, offline, local }

class AudioQuality {
  const AudioQuality(this.kind, this.label);

  final AudioQualityKind kind;

  /// 画面に出す短い文字列（「高音質 AAC 128kbps」「標準 96kbps」など）
  final String label;

  /// YouTube の一体型ストリーム（360p、AAC 約 96kbps）
  static const standard = AudioQuality(AudioQualityKind.standard, '標準 96kbps');

  /// オフライン保存したファイル（保存時の画質で音声も決まる）
  static const offline = AudioQuality(AudioQualityKind.offline, 'オフライン');

  /// 端末のローカル動画
  static const local = AudioQuality(AudioQualityKind.local, 'ローカル');

  /// 高音質（音声専用ストリームを付けられた）
  factory AudioQuality.hq(String streamLabel) =>
      AudioQuality(AudioQualityKind.hq, '高音質 $streamLabel');

  bool get isHq => kind == AudioQualityKind.hq;

  @override
  bool operator ==(Object other) =>
      other is AudioQuality && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => label;
}
