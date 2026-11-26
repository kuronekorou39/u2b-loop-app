import Flutter
import UIKit
import AVFoundation
import AVKit
import IOSurface

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var waveformTask: Task<Void, Never>?
  var pipManager: PiPManager?
  // チャネルをインスタンスで保持（ARC でハンドラが解除されるのを防ぐ）
  private var exportChannel: FlutterMethodChannel?
  private var waveformChannel: FlutterMethodChannel?
  private var pipChannel: FlutterMethodChannel?
  private weak var pipWindow: UIWindow?
  private var regionExport: AVAssetExportSession?
  private var regionExportBusy = false
  private var regionExportCancelled = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    AVAudioSession.ignoreDeactivation()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // media_kit が映像のテクスチャを登録する前に、登録を見張る（PiP の小窓に映像を流すため）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "U2BLoopTextures") {
      PiPFrameSource.hook(registry: registrar.textures())
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Scene ベースのライフサイクルでは didFinishLaunchingWithOptions 時点で
    // window が nil のため、エンジン初期化完了後にチャネルを登録する
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "U2BLoopChannels")
    else { return }
    let messenger: FlutterBinaryMessenger = registrar.messenger()

    // --- Export channel ---
    let ec = FlutterMethodChannel(name: "com.u2bloop/export", binaryMessenger: messenger)
    self.exportChannel = ec
    ec.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "exportRegion":
        self?.handleExportRegion(call: call, result: result)
      case "exportRegions":
        self?.handleExportRegions(call: call, result: result)
      case "cancelExportRegions":
        self?.cancelRegionExport()
        result(nil)
      case "muxVideoAudio":
        self?.handleMuxVideoAudio(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // --- Waveform channel ---
    let wc = FlutterMethodChannel(name: "com.u2bloop/waveform", binaryMessenger: messenger)
    self.waveformChannel = wc
    wc.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "extractAmplitudes":
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String else {
          result(FlutterError(code: "INVALID", message: "URL is null", details: nil))
          return
        }
        self?.startExtraction(
          url: url, withPcm: args["withPcm"] as? Bool ?? false, result: result)
      case "cancelExtraction":
        self?.cancelExtraction()
        result(nil as Any?)
      case "decodeSegment":
        // DJ の演出の材料。波形の抽出とは別に動く（中止しない）
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String,
              let startMs = (args["startMs"] as? NSNumber)?.int64Value,
              let endMs = (args["endMs"] as? NSNumber)?.int64Value,
              startMs >= 0, endMs > startMs, endMs - startMs <= segmentMaxMs else {
          result(FlutterError(code: "INVALID", message: "bad segment", details: nil))
          return
        }
        Task.detached {
          do {
            let segment = try await decodeAudioSegment(url: url, startMs: startMs, endMs: endMs)
            await MainActor.run { result(segment) }
          } catch {
            await MainActor.run {
              result(FlutterError(
                code: "DECODE_ERROR", message: error.localizedDescription, details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // --- PiP channel ---
    let pc = FlutterMethodChannel(name: "com.u2bloop/pip", binaryMessenger: messenger)
    self.pipChannel = pc
    pc.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      let args = call.arguments as? [String: Any] ?? [:]
      // 映像の出どころと位置は、PiP の準備より先に届いても覚えておく
      switch call.method {
      case "setPiPVideoTexture":
        PiPFrameSource.activeTextureId = (args["textureId"] as? NSNumber)?.int64Value
        PiPFrameSource.note("active texture \(String(describing: PiPFrameSource.activeTextureId))")
        result(true)
        return
      case "setPiPSourceRect":
        PiPFrameSource.sourceRect = CGRect(
          x: (args["x"] as? NSNumber)?.doubleValue ?? 0,
          y: (args["y"] as? NSNumber)?.doubleValue ?? 0,
          width: (args["width"] as? NSNumber)?.doubleValue ?? 0,
          height: (args["height"] as? NSNumber)?.doubleValue ?? 0)
        self?.pipManager?.applySourceRect()
        result(true)
        return
      default:
        break
      }
      guard let manager = self?.pipManager else {
        result(false)
        return
      }
      switch call.method {
      case "enterPiP":
        let args = call.arguments as? [String: Any]
        manager.updateThumbnail(
          url: args?["thumbnailUrl"] as? String,
          localPath: args?["thumbnailPath"] as? String
        )
        // Dart 側は入れたかどうかの bool を受け取る
        result(manager.enterPiPWithDiag()["ok"] as? Bool ?? false)
      case "setAutoPiP":
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = args["enabled"] as? Bool ?? false
        let isPlaylist = args["isPlaylist"] as? Bool ?? false
        manager.setAutoPiP(enabled: enabled, isPlaylist: isPlaylist)
        manager.updateThumbnail(
          url: args["thumbnailUrl"] as? String,
          localPath: args["thumbnailPath"] as? String
        )
        result(true)
      case "updatePiPPlayState":
        let args = call.arguments as? [String: Any] ?? [:]
        let playing = args["playing"] as? Bool ?? false
        manager.updatePlayState(playing: playing)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    DispatchQueue.main.async { [weak self] in
      self?.setupPiPIfReady()
    }
  }

  /// SceneDelegate から: シーンの window ができた
  func attachPiP(window: UIWindow) {
    pipWindow = window
    setupPiPIfReady()
  }

  /// Scene ベースのアプリでは AppDelegate の window が nil なので、シーンの window を使う。
  /// チャネルと window のどちらが先にそろっても動くよう、両方の経路から呼ぶ
  private func setupPiPIfReady() {
    guard pipManager == nil, let window = pipWindow, let channel = pipChannel,
          window.rootViewController != nil else { return }
    let manager = PiPManager()
    manager.setup(in: window, channel: channel)
    pipManager = manager
  }

  // MARK: - Export Region

  private func handleExportRegion(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inputUri = args["inputUri"] as? String,
          let startMs = args["startMs"] as? Int,
          let endMs = args["endMs"] as? Int else {
      result(["success": false, "error": "パラメータが不正です"])
      return
    }

    let audioOnly = args["audioOnly"] as? Bool ?? false
    let title = args["title"] as? String ?? "export"

    let outputPath = exportOutputPath(title: title, audioOnly: audioOnly)
    guard let assetURL = mediaURL(inputUri) else {
      result(["success": false, "error": "無効な入力です"])
      return
    }

    let asset = AVURLAsset(url: assetURL)
    let startTime = CMTime(value: CMTimeValue(startMs), timescale: 1000)
    let endTime = CMTime(value: CMTimeValue(endMs), timescale: 1000)
    let timeRange = CMTimeRange(start: startTime, end: endTime)

    // Choose export preset
    let presetName = audioOnly
      ? AVAssetExportPresetAppleM4A
      : AVAssetExportPresetPassthrough

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
      result(["success": false, "error": "エクスポートセッションを作成できません"])
      return
    }

    exportSession.outputURL = URL(fileURLWithPath: outputPath)
    exportSession.outputFileType = audioOnly ? AVFileType.m4a : AVFileType.mp4
    exportSession.timeRange = timeRange

    exportSession.exportAsynchronously {
      DispatchQueue.main.async {
        switch exportSession.status {
        case .completed:
          result(["success": true, "outputPath": outputPath])
        case .failed:
          let error = exportSession.error?.localizedDescription ?? "不明なエラー"
          result(["success": false, "error": error])
        case .cancelled:
          result(["success": false, "error": "エクスポートがキャンセルされました"])
        default:
          result(["success": false, "error": "エクスポート失敗 (status: \(exportSession.status.rawValue))"])
        }
      }
    }
  }

  // MARK: - Export Regions / Mux

  /// 書き出し先（同じ名前の前回の分は消す）
  private func exportOutputPath(title: String, audioOnly: Bool) -> String {
    let cleaned = String(
      title.replacingOccurrences(of: "[^a-zA-Z0-9\\p{Han}\\p{Hiragana}\\p{Katakana}_ -]",
                                  with: "",
                                  options: .regularExpression)
        .prefix(50)
    )
    let name = cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "export" : cleaned
    let path = NSTemporaryDirectory() + "\(name).\(audioOnly ? "m4a" : "mp4")"
    try? FileManager.default.removeItem(atPath: path)
    return path
  }

  /// 複数の区間を 1 本につなぐ。区間の端で正確に切るため再エンコードする
  private func handleExportRegions(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inputUri = args["inputUri"] as? String,
          let url = mediaURL(inputUri),
          let starts = args["startsMs"] as? [NSNumber],
          let ends = args["endsMs"] as? [NSNumber],
          !starts.isEmpty, starts.count == ends.count else {
      result(FlutterError(code: "INVALID", message: "Missing parameters", details: nil))
      return
    }
    guard !regionExportBusy else {
      result(["success": false, "error": "ほかの書き出しの途中です"])
      return
    }
    regionExportBusy = true
    regionExportCancelled = false
    let audioOnly = args["audioOnly"] as? Bool ?? false
    let outputPath = exportOutputPath(
      title: args["title"] as? String ?? "export", audioOnly: audioOnly)
    let ranges = zip(starts, ends).map { ($0.int64Value, $1.int64Value) }

    Task { @MainActor [weak self] in
      let finish: ([String: Any]) -> Void = { value in
        self?.regionExport = nil
        self?.regionExportBusy = false
        result(value)
      }
      do {
        let composition = try await buildRegionComposition(
          url: url, ranges: ranges, audioOnly: audioOnly)
        if self?.regionExportCancelled ?? true {
          finish(["success": false, "cancelled": true])
          return
        }
        let preset = audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
          finish(["success": false, "error": "エクスポートセッションを作成できません"])
          return
        }
        session.outputURL = URL(fileURLWithPath: outputPath)
        session.outputFileType = audioOnly ? .m4a : .mp4
        self?.regionExport = session

        let progress = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
          DispatchQueue.main.async {
            self?.exportChannel?.invokeMethod(
              "exportProgress", arguments: Int(session.progress * 100))
          }
        }
        await runExport(session)
        progress.invalidate()

        switch session.status {
        case .completed:
          finish(["success": true, "outputPath": outputPath])
        case .cancelled:
          try? FileManager.default.removeItem(atPath: outputPath)
          finish(["success": false, "cancelled": true])
        default:
          try? FileManager.default.removeItem(atPath: outputPath)
          finish(["success": false, "error": session.error?.localizedDescription ?? "不明なエラー"])
        }
      } catch {
        finish(["success": false, "error": error.localizedDescription])
      }
    }
  }

  private func cancelRegionExport() {
    regionExportCancelled = true
    regionExport?.cancelExport()
  }

  /// 別々に落とした映像専用・音声専用のファイルを 1 つの MP4 にする（再エンコードなし）
  private func handleMuxVideoAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let videoPath = args["videoPath"] as? String,
          let audioPath = args["audioPath"] as? String,
          let outputPath = args["outputPath"] as? String else {
      result(FlutterError(code: "INVALID", message: "Missing parameters", details: nil))
      return
    }
    Task { @MainActor in
      let failed: (String) -> Void = { message in
        try? FileManager.default.removeItem(atPath: outputPath)
        result(["success": false, "error": message])
      }
      do {
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)

        // 出力先の拡張子が .mp4 とは限らないので、いったん .mp4 に書いてから移す
        let working = output.deletingLastPathComponent()
          .appendingPathComponent("mux_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: working) }
        try await remuxVideoAudio(
          video: URL(fileURLWithPath: videoPath),
          audio: URL(fileURLWithPath: audioPath),
          output: working)
        try FileManager.default.moveItem(at: working, to: output)
        result(["success": true, "outputPath": outputPath])
      } catch {
        failed(error.localizedDescription)
      }
    }
  }

  // MARK: - Waveform Extraction

  private func startExtraction(url: String, withPcm: Bool, result: @escaping FlutterResult) {
    waveformTask?.cancel()
    waveformTask = Task.detached { [weak self] in
      do {
        let decimator = withPcm ? MonoDecimator() : nil
        let amplitudes =
          try await self?.extractAudioAmplitudes(url: url, decimator: decimator) ?? []
        await MainActor.run {
          if let decimator = decimator {
            // テンポ・キーの解析には間引いたモノラル PCM も要る（Android と同じ形）
            result([
              "amplitudes": amplitudes,
              "pcm": FlutterStandardTypedData(bytes: decimator.littleEndianBytes()),
              "sampleRate": MonoDecimator.outRate,
            ] as [String: Any])
          } else {
            result(amplitudes)
          }
        }
      } catch is CancellationError {
        await MainActor.run { result([Int]()) }
      } catch {
        await MainActor.run {
          result(FlutterError(code: "EXTRACT_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func cancelExtraction() {
    waveformTask?.cancel()
    waveformTask = nil
  }

  private func extractAudioAmplitudes(url: String, decimator: MonoDecimator?) async throws -> [Int] {
    let assetURL: URL
    if url.hasPrefix("http://") || url.hasPrefix("https://") {
      guard let u = URL(string: url) else { return [] }
      assetURL = u
    } else if url.hasPrefix("file://") {
      guard let u = URL(string: url) else { return [] }
      assetURL = u
    } else {
      assetURL = URL(fileURLWithPath: url)
    }

    let asset = AVURLAsset(url: assetURL)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      return []
    }

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    reader.add(output)
    reader.startReading()
    defer { reader.cancelReading() }

    var amplitudes = [Int]()
    let maxAmplitudes = 100_000
    // Android の MediaCodec 出力と同等の粒度（AACの1フレーム ≒ 1024サンプル）
    let samplesPerWindow = 1024

    while reader.status == .reading && amplitudes.count < maxAmplitudes {
      try Task.checkCancellation()

      guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
      guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

      let length = CMBlockBufferGetDataLength(blockBuffer)
      let totalSamples = length / 2
      guard totalSamples > 0 else { continue }

      if let decimator = decimator,
         let format = CMSampleBufferGetFormatDescription(sampleBuffer),
         let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
        decimator.configure(inRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
      }

      var data = Data(count: length)
      data.withUnsafeMutableBytes { ptr in
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                   destination: ptr.baseAddress!)
      }

      data.withUnsafeBytes { rawBuffer in
        let samples = rawBuffer.bindMemory(to: Int16.self)
        if let decimator = decimator {
          for i in 0..<totalSamples { decimator.push(samples[i]) }
        }
        var offset = 0
        while offset < totalSamples && amplitudes.count < maxAmplitudes {
          let windowEnd = min(offset + samplesPerWindow, totalSamples)
          var sumSquares: Int64 = 0
          for i in offset..<windowEnd {
            let s = Int64(samples[i])
            sumSquares += s * s
          }
          let count = windowEnd - offset
          let rms = Int(sqrt(Double(sumSquares) / Double(count)))
          amplitudes.append(rms)
          offset = windowEnd
        }
      }
    }

    return amplitudes
  }
}

// MARK: - Media helpers

/// decodeSegment で一度に取り出せる長さ（Android と同じ）
private let segmentMaxMs: Int64 = 15_000

private enum MediaError: LocalizedError {
  case noTrack
  case emptyRange

  var errorDescription: String? {
    switch self {
    case .noTrack: return "書き出せるトラックがありません"
    case .emptyRange: return "書き出す区間がありません"
    }
  }
}

/// パス・file:// ・http(s) のどれでも URL にする
private func mediaURL(_ uri: String) -> URL? {
  if uri.hasPrefix("http://") || uri.hasPrefix("https://") || uri.hasPrefix("file://") {
    return URL(string: uri)
  }
  return URL(fileURLWithPath: uri)
}

private func milliseconds(_ ms: Int64) -> CMTime {
  CMTime(value: CMTimeValue(ms), timescale: 1000)
}

private func runExport(_ session: AVAssetExportSession) async {
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    session.exportAsynchronously { continuation.resume() }
  }
}

/// [ranges] を順につないだコンポジション
private func buildRegionComposition(
  url: URL, ranges: [(Int64, Int64)], audioOnly: Bool
) async throws -> AVMutableComposition {
  let asset = AVURLAsset(url: url)
  var sourceVideo: AVAssetTrack?
  if !audioOnly { sourceVideo = try await asset.loadTracks(withMediaType: .video).first }
  let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
  guard sourceVideo != nil || sourceAudio != nil else { throw MediaError.noTrack }

  let composition = AVMutableComposition()
  var video: AVMutableCompositionTrack?
  var videoRange = CMTimeRange.zero
  if let source = sourceVideo {
    video = composition.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    video?.preferredTransform = try await source.load(.preferredTransform)
    videoRange = try await source.load(.timeRange)
  }
  var audio: AVMutableCompositionTrack?
  var audioRange = CMTimeRange.zero
  if let source = sourceAudio {
    audio = composition.addMutableTrack(
      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    audioRange = try await source.load(.timeRange)
  }

  let whole = try await asset.load(.duration)
  var cursor = CMTime.zero
  for (startMs, endMs) in ranges {
    let range = CMTimeRange(start: milliseconds(startMs), end: min(milliseconds(endMs), whole))
    guard range.duration > .zero else { continue }
    if let source = sourceVideo, let track = video {
      let part = range.intersection(videoRange)
      if part.duration > .zero { try track.insertTimeRange(part, of: source, at: cursor) }
    }
    if let source = sourceAudio, let track = audio {
      let part = range.intersection(audioRange)
      if part.duration > .zero {
        try track.insertTimeRange(
          part, of: source, at: cursor + (part.start - range.start))
      }
    }
    cursor = cursor + range.duration
  }
  guard cursor > .zero else { throw MediaError.emptyRange }
  return composition
}

/// 1 トラック分のサンプルを読み手から書き手へそのまま流す
private final class SamplePump {
  private let input: AVAssetWriterInput
  private let output: AVAssetReaderTrackOutput
  private let queue: DispatchQueue
  private var finished = false

  /// 書いたサンプルの終わりの時刻
  private(set) var end = CMTime.zero
  private(set) var failed = false

  init(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput, label: String) {
    self.input = input
    self.output = output
    queue = DispatchQueue(label: "com.u2bloop.mux.\(label)")
  }

  func run() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      input.requestMediaDataWhenReady(on: queue) { [self] in
        guard !finished else { return }
        while input.isReadyForMoreMediaData {
          guard let sample = output.copyNextSampleBuffer() else {
            stop(continuation)
            return
          }
          // 読み手は最後にサンプルを含まない印（時刻が元の長さの 2 倍のことがある）を渡してくる。
          // そのまま書くとトラックがそこまで伸びて動画の長さが 2 倍になるので書かない
          guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
          track(sample)
          guard input.append(sample) else {
            failed = true
            stop(continuation)
            return
          }
        }
      }
    }
  }

  private func stop(_ continuation: CheckedContinuation<Void, Never>) {
    finished = true
    input.markAsFinished()
    continuation.resume()
  }

  /// 書いたサンプルの終わりの時刻を進める
  private func track(_ sample: CMSampleBuffer) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    guard pts.isValid else { return }
    end = max(end, duration.isValid ? pts + duration : pts)
  }
}

/// 映像ファイルの映像と音声ファイルの音声を再エンコードせずに 1 つの MP4 にする
private func remuxVideoAudio(video: URL, audio: URL, output: URL) async throws {
  let videoAsset = AVURLAsset(url: video)
  guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
        let videoFormat = try await videoTrack.load(.formatDescriptions).first else {
    throw MediaError.noTrack
  }
  let transform = try await videoTrack.load(.preferredTransform)
  let audioAsset = AVURLAsset(url: audio)
  let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
  let audioFormat = try await audioTrack?.load(.formatDescriptions).first

  let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
  writer.shouldOptimizeForNetworkUse = true

  let videoReader = try AVAssetReader(asset: videoAsset)
  let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
  videoOutput.alwaysCopiesSampleData = false
  videoReader.add(videoOutput)
  let videoInput = AVAssetWriterInput(
    mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
  videoInput.expectsMediaDataInRealTime = false
  videoInput.transform = transform
  writer.add(videoInput)
  var pumps = [SamplePump(input: videoInput, output: videoOutput, label: "video")]

  var audioReader: AVAssetReader?
  if let audioTrack = audioTrack, let audioFormat = audioFormat {
    let reader = try AVAssetReader(asset: audioAsset)
    let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    trackOutput.alwaysCopiesSampleData = false
    reader.add(trackOutput)
    let audioInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
    audioInput.expectsMediaDataInRealTime = false
    writer.add(audioInput)
    pumps.append(SamplePump(input: audioInput, output: trackOutput, label: "audio"))
    audioReader = reader
  }

  guard videoReader.startReading() else { throw videoReader.error ?? MediaError.noTrack }
  defer { videoReader.cancelReading() }
  if let reader = audioReader, !reader.startReading() {
    throw reader.error ?? MediaError.noTrack
  }
  defer { audioReader?.cancelReading() }
  guard writer.startWriting() else { throw writer.error ?? MediaError.noTrack }
  writer.startSession(atSourceTime: .zero)

  // 書き手は映像と音声を交互に受け取るので、同時に流す
  await withTaskGroup(of: Void.self) { group in
    for pump in pumps {
      group.addTask { await pump.run() }
    }
  }

  if pumps.contains(where: { $0.failed }) || videoReader.status == .failed
    || audioReader?.status == .failed {
    let cause = writer.error ?? videoReader.error ?? audioReader?.error
    writer.cancelWriting()
    throw cause ?? MediaError.noTrack
  }
  if let sessionEnd = pumps.map(\.end).max(), sessionEnd > .zero {
    writer.endSession(atSourceTime: sessionEnd)
  }
  await writer.finishWriting()
  if writer.status != .completed { throw writer.error ?? MediaError.noTrack }
}

/// 曲の [startMs, endMs) を、元のサンプルレート・チャンネル数の 16bit PCM で返す
private func decodeAudioSegment(url: String, startMs: Int64, endMs: Int64) async throws
  -> [String: Any] {
  guard let assetURL = mediaURL(url) else { return ["pcm": NSNull()] }
  let asset = AVURLAsset(url: assetURL)
  guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
    return ["pcm": NSNull()]
  }
  let reader = try AVAssetReader(asset: asset)
  reader.timeRange = CMTimeRange(start: milliseconds(startMs), end: milliseconds(endMs))
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ])
  reader.add(output)
  guard reader.startReading() else {
    throw reader.error ?? MediaError.noTrack
  }
  defer { reader.cancelReading() }

  var pcm = Data()
  var sampleRate = 0
  var channels = 0
  while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
    if sampleRate == 0,
       let format = CMSampleBufferGetFormatDescription(buffer),
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
      sampleRate = Int(asbd.mSampleRate)
      channels = Int(asbd.mChannelsPerFrame)
    }
    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { continue }
    var chunk = Data(count: length)
    let status = chunk.withUnsafeMutableBytes { ptr in
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
    }
    if status == kCMBlockBufferNoErr { pcm.append(chunk) }
  }
  if reader.status == .failed { throw reader.error ?? MediaError.noTrack }
  guard !pcm.isEmpty, sampleRate > 0, channels > 0 else { return ["pcm": NSNull()] }
  return [
    "pcm": FlutterStandardTypedData(bytes: pcm),
    "sampleRate": sampleRate,
    "channels": channels,
  ]
}

// MARK: - Analysis PCM

/// テンポ・キー解析用に、インターリーブの PCM をモノラル 11025Hz に間引く
/// （Android の MainActivity.MonoDecimator と同じ手順）
private final class MonoDecimator {
  static let outRate = 11025
  private static let maxSeconds = 480

  private var out = [Int16]()
  private var channels = 0
  private var ratio = 1.0
  private var next = 1.0
  private var frameSum = 0
  private var ch = 0
  private var acc = 0.0
  private var count = 0
  private var pos = 0

  /// 最初のバッファの形式で一度だけ決める
  func configure(inRate: Double, channels: Int) {
    guard self.channels == 0, channels > 0, inRate > 0 else { return }
    self.channels = channels
    ratio = inRate / Double(Self.outRate)
    next = ratio
    out.reserveCapacity(Self.outRate * Self.maxSeconds)
  }

  func push(_ sample: Int16) {
    guard channels > 0 else { return }
    frameSum += Int(sample)
    ch += 1
    if ch < channels { return }
    acc += Double(frameSum) / Double(channels)
    frameSum = 0
    ch = 0
    count += 1
    pos += 1
    if Double(pos) >= next {
      if out.count < Self.outRate * Self.maxSeconds {
        out.append(Int16(max(-32768, min(32767, Int(acc / Double(count))))))
      }
      acc = 0
      count = 0
      next += ratio
    }
  }

  func littleEndianBytes() -> Data {
    out.withUnsafeBufferPointer { Data(buffer: $0) }
  }
}

// MARK: - PiP Manager

class PiPManager: NSObject, AVPictureInPictureControllerDelegate,
                  AVPictureInPictureSampleBufferPlaybackDelegate {
  private var pipController: AVPictureInPictureController?
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var pipView: UIView?
  private weak var pipWindowRef: UIWindow?
  private weak var channel: FlutterMethodChannel?

  private var autoPipEnabled = false
  private(set) var isPlaying = false
  private var isPlaylist = false
  private var lastPoster: UIImage?

  func setup(in window: UIWindow, channel: FlutterMethodChannel) {
    self.channel = channel
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

    // PiP には .playback のオーディオセッションが要る。
    // 起動しただけで他のアプリの音を止めないよう、有効にするのは PiP に入るときだけ
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    self.displayLayer = layer

    // PiP には view hierarchy に追加された layer が要る。iOS はこの layer の位置から小窓へ縮め、
    // 戻るときはこの位置へ広げるので、再生画面の動画と同じ位置・大きさに置く（applySourceRect）。
    // アプリの画面（Flutter）の裏に置くので、ふだんは見えない
    let view = UIView(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
    // 切り抜かないと、小窓を閉じた後も絵がアプリの左上に残る
    view.clipsToBounds = true
    view.isUserInteractionEnabled = false
    view.layer.addSublayer(layer)
    layer.frame = CGRect(x: 0, y: 0, width: 300, height: 169)
    pipWindowRef = window
    if let root = window.rootViewController?.view, let parent = root.superview {
      parent.insertSubview(view, belowSubview: root)
    } else {
      // アプリの画面がまだ window に付いていなければ、いちばん奥に置く（後から付く画面が手前になる）
      window.insertSubview(view, at: 0)
    }
    self.pipView = view
    applySourceRect()

    // デフォルトの黒フレームを投入（サムネイル未ロード時のフォールバック）
    enqueueBlackFrame(width: 300, height: 169)

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    self.pipController = controller
  }

  func enterPiP() -> Bool {
    guard let pip = pipController else { return false }
    if pip.isPictureInPictureActive { return true }
    if !pip.isPictureInPicturePossible { return false }
    pip.startPictureInPicture()
    return true
  }

  /// 診断情報付き enterPiP（デバッグ用）
  func enterPiPWithDiag() -> [String: Any] {
    try? AVAudioSession.sharedInstance().setActive(true)
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    let hasController = pipController != nil
    let hasLayer = displayLayer != nil
    let possible = pipController?.isPictureInPicturePossible ?? false
    let active = pipController?.isPictureInPictureActive ?? false
    let layerReady = displayLayer?.isReadyForMoreMediaData ?? false
    let layerStatus = displayLayer?.status.rawValue ?? -1

    var diag: [String: Any] = [
      "supported": supported,
      "hasController": hasController,
      "hasLayer": hasLayer,
      "possible": possible,
      "active": active,
      "layerReady": layerReady,
      "layerStatus": layerStatus,
    ]

    if !supported {
      diag["error"] = "PiP not supported on this device"
    } else if !hasController {
      diag["error"] = "PiP controller not initialized"
    } else if active {
      diag["ok"] = true
    } else if !possible {
      diag["error"] = "PiP not possible (isPictureInPicturePossible=false)"
    } else {
      beginFrames()
      pipController!.startPictureInPicture()
      diag["ok"] = true
    }
    return diag
  }

  private func enqueueBlackFrame(width: Int, height: Int) {
    guard let layer = displayLayer else { return }
    var pixelBuffer: CVPixelBuffer?
    // 小窓の表示層は IOSurface 付きのバッファでないと真っ黒になる
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
    guard let pb = pixelBuffer else { return }

    // ゼロクリア（黒）
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)
    memset(base, 0, CVPixelBufferGetDataSize(pb))
    CVPixelBufferUnlockBaseAddress(pb, [])

    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDesc
    )
    guard let format = formatDesc else { return }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 1),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
      makeDataReadyCallback: nil, refcon: nil,
      formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let buffer = sampleBuffer else { return }
    markDisplayImmediately(buffer)
    layer.flush()
    layer.enqueue(buffer)
  }

  /// 再生画面の動画の位置に合わせる（まだ届いていなければ今のまま）
  func applySourceRect() {
    guard let rect = PiPFrameSource.sourceRect, rect.width > 1, rect.height > 1,
          let view = pipView, let layer = displayLayer else { return }
    view.frame = rect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = view.bounds
    CATransaction.commit()
  }

  // MARK: - 小窓に映像を流す（試作）

  private var frameTimer: DispatchSourceTimer?
  private var lastFrame: CVPixelBuffer?
  private var lastSeed: UInt32 = 0
  private var pumped = 0
  private var pumpTicks = 0

  /// PiP の間、鳴っているプレイヤーの映像を 30fps で小窓に流す。取れなければサムネのまま
  /// 小窓に縮み始める前から今のコマを映しておく（入りの間サムネが映ってから動画に切り替わると、
  /// サムネ → カクッ → 動画 に見える）。流れていれば何もしない
  func beginFrames() {
    guard frameTimer == nil else { return }
    startFramePump()
  }

  private func startFramePump() {
    stopFramePump()
    pumped = 0
    pumpTicks = 0
    // コマの時刻はホストの時計で付けるので、表示層の時計もそれに合わせる（1 度だけ。付け直すとちらつく）
    if let layer = displayLayer, layer.controlTimebase == nil {
      var timebase: CMTimebase?
      CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
        timebaseOut: &timebase)
      if let tb = timebase {
        CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(tb, rate: 1)
        layer.controlTimebase = tb
      }
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(33))
    timer.setEventHandler { [weak self] in self?.pumpFrame() }
    frameTimer = timer
    // 最初のコマはタイマーを待たずに今すぐ積む
    pumpFrame()
    timer.resume()
  }

  private func stopFramePump() {
    frameTimer?.cancel()
    frameTimer = nil
    lastFrame = nil
  }

  private func pumpFrame() {
    pumpTicks += 1
    if pumpTicks == 60 { dumpPumpState("after 2s") }
    // 流し始めて 3 秒たっても小窓に入っていなければ止める（入れなかったとき裏で回り続けない）
    if pumpTicks > 90, pipController?.isPictureInPictureActive != true {
      stopFramePump()
      return
    }
    guard let layer = displayLayer,
          let frame = PiPFrameSource.currentFrame() else { return }
    // mpv は同じバッファに描き直すので、バッファが同じでも中身（IOSurface の seed）が
    // 変わっていれば積む。止まっている間は積み直さない
    let seed = CVPixelBufferGetIOSurface(frame).map {
      IOSurfaceGetSeed($0.takeUnretainedValue())
    } ?? 0
    if let last = lastFrame, last === frame, seed != 0, seed == lastSeed { return }
    guard let buffer = PiPFrameSource.sampleBuffer(for: frame) else {
      PiPFrameSource.note("sampleBuffer failed")
      return
    }
    if pumped == 0 {
      PiPFrameSource.note(
        "first frame \(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)) "
          + "fmt \(CVPixelBufferGetPixelFormatType(frame)) "
          + "surface \(CVPixelBufferGetIOSurface(frame) != nil)")
    }
    lastFrame = frame
    lastSeed = seed
    pumped += 1
    markDisplayImmediately(buffer)
    if layer.status == .failed {
      PiPFrameSource.note("layer failed: \(String(describing: layer.error))")
      layer.flush()
    }
    layer.enqueue(buffer)
  }

  /// 小窓から戻ると、iOS が置いた絵の層がアプリの画面（Flutter）より手前に残り、
  /// シートが動画の下に潜ったり、画面を移っても動画が残ったりする。アプリの画面の裏へ置き直す
  private func sendBehindApp() {
    guard let view = pipView, let window = view.window ?? pipWindowRef,
          let root = window.rootViewController?.view else { return }
    let before = window.subviews.firstIndex(of: view) ?? -1
    let rootBefore = window.subviews.firstIndex(of: root) ?? -1
    view.removeFromSuperview()
    if let parent = root.superview {
      parent.insertSubview(view, belowSubview: root)
    } else {
      window.insertSubview(view, at: 0)
    }
    PiPFrameSource.note(
      "sendBehind: pip \(before) root \(rootBefore) of \(window.subviews.count) -> "
        + "pip \(window.subviews.firstIndex(of: view) ?? -1) "
        + "root \(window.subviews.firstIndex(of: root) ?? -1) "
        + "rootParentIsWindow \(root.superview === window)")
  }

  private func dumpPumpState(_ label: String) {
    let layer = displayLayer
    PiPFrameSource.dump(
      "\(label): active \(String(describing: PiPFrameSource.activeTextureId)) "
        + "pumped \(pumped)/\(pumpTicks) layerStatus \(layer?.status.rawValue ?? -1) "
        + "error \(String(describing: layer?.error))")
  }

  func setAutoPiP(enabled: Bool, isPlaylist: Bool) {
    self.autoPipEnabled = enabled
    self.isPlaylist = isPlaylist
  }

  func updatePlayState(playing: Bool) {
    if playing != isPlaying {
      PiPFrameSource.note("playState from app \(playing) pipActive \(pipController?.isPictureInPictureActive ?? false)")
    }
    self.isPlaying = playing
    pipController?.invalidatePlaybackState()
  }

  /// SceneDelegate から呼ばれる: バックグラウンド遷移時の自動 PiP
  func startPiPIfNeeded() {
    guard autoPipEnabled, isPlaying,
          let pip = pipController,
          !pip.isPictureInPictureActive,
          AVPictureInPictureController.isPictureInPictureSupported() else { return }
    try? AVAudioSession.sharedInstance().setActive(true)
    beginFrames()
    pip.startPictureInPicture()
  }

  // MARK: - Thumbnail

  func updateThumbnail(url: String?, localPath: String?) {
    if let path = localPath, let image = UIImage(contentsOfFile: path) {
      enqueuePosterFrame(image)
    } else if let urlString = url, let url = URL(string: urlString) {
      URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let data = data, let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { self?.enqueuePosterFrame(image) }
      }.resume()
    }
  }

  /// 時刻を待たずにすぐ表示させる（静止画なので再生の時計が無い）
  private func markDisplayImmediately(_ buffer: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      buffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 else { return }
    let dict = unsafeBitCast(
      CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
      dict,
      Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
  }

  private func enqueuePosterFrame(_ image: UIImage) {
    lastPoster = image
    guard let layer = displayLayer,
          let pixelBuffer = pixelBufferFromImage(image) else { return }

    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDesc
    )
    guard let format = formatDesc else { return }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 1),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let buffer = sampleBuffer else { return }

    markDisplayImmediately(buffer)
    layer.flush()
    layer.enqueue(buffer)
  }

  private func pixelBufferFromImage(_ image: UIImage) -> CVPixelBuffer? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height

    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    guard let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(pb),
      width: width, height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                  CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pb
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    // ほかの経路（iOS が自分で始めたときなど）でも、縮み始める前にコマを流し始める
    PiPFrameSource.note("willStart")
    beginFrames()
    channel?.invokeMethod("onPiPChanged", arguments: true)
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    PiPFrameSource.note("didStart")
    beginFrames()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    // 始める前に流し始めたコマを止める（入れなかったのに裏で回り続けないように）
    stopFramePump()
    PiPFrameSource.note("failed to start: \(error.localizedDescription)")
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    applySourceRect()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    stopFramePump()
    sendBehindApp()
    // 最後のコマが残らないよう、サムネに戻しておく（次の PiP の入りもサムネから）
    if let image = lastPoster {
      enqueuePosterFrame(image)
    } else {
      displayLayer?.flushAndRemoveImage()
    }
    dumpPumpState("stop")
    channel?.invokeMethod("onPiPChanged", arguments: false)
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // 小窓に入る・戻るときにも iOS が呼んでくる。切り替えとして扱うと再生が止まるので、
    // 今と違うときだけ送る
    PiPFrameSource.note("setPlaying from iOS \(playing) (app \(isPlaying))")
    guard playing != isPlaying else { return }
    channel?.invokeMethod("onPiPAction", arguments: "playPause")
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval interval: CMTime,
    completion: @escaping () -> Void
  ) {
    let action = interval.seconds > 0 ? "next" : "prev"
    channel?.invokeMethod("onPiPAction", arguments: action)
    completion()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    // 長時間の範囲を返してスクラバーを無効化
    return CMTimeRange(start: .zero, duration: CMTime(value: 36000, timescale: 1))
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    return !isPlaying
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // no-op
  }
}

// MARK: - 音声セッションの無効化を無視する

extension AVAudioSession {
  /// mpv（media_kit）の iOS の音声出力は、プレイヤーを止めるたびに音声セッションを無効にする
  /// （ao_audiounit.m の uninit が setActive:NO を無条件に呼ぶ）。セッションはアプリで 1 つなので、
  /// プレイヤーを 3 台使い回すこのアプリでは、前の曲を止めた瞬間に鳴っている曲の音まで止まっていた。
  /// アプリ自身は無効にする必要が無いので、無効化だけ握りつぶす（有効化はそのまま通す）
  static func ignoreDeactivation() {
    guard !deactivationIgnored,
          let original = class_getInstanceMethod(
            AVAudioSession.self, #selector(AVAudioSession.setActive(_:options:))),
          let replacement = class_getInstanceMethod(
            AVAudioSession.self, #selector(AVAudioSession.u2b_setActive(_:options:)))
    else { return }
    method_exchangeImplementations(original, replacement)
    deactivationIgnored = true
  }

  private static var deactivationIgnored = false

  @objc dynamic func u2b_setActive(
    _ active: Bool, options: AVAudioSession.SetActiveOptions
  ) throws {
    guard active else { return }
    // 入れ替え済みなので、これは元の setActive(_:options:) を呼ぶ
    try u2b_setActive(active, options: options)
  }
}

// MARK: - PiP の小窓に流す映像の出どころ

/// media_kit_video が登録する映像のテクスチャ（FlutterTexture）を番号ごとに覚えておき、
/// いま鳴っているプレイヤーのコマを取り出す。
/// PiP の間はアプリが裏に回って Flutter が描かないので、テクスチャから直接コマを読む（試作）
enum PiPFrameSource {
  /// 鳴っているプレイヤーの映像のテクスチャ番号（Dart から届く）
  static var activeTextureId: Int64?
  /// 再生画面の動画の位置と大きさ（Dart から届く、論理座標）
  static var sourceRect: CGRect?

  private final class WeakTexture {
    weak var texture: NSObject?
    init(_ texture: NSObject) { self.texture = texture }
  }

  private static var textures: [Int64: WeakTexture] = [:]
  private static let lock = NSLock()
  private static var hookedClasses = Set<ObjectIdentifier>()

  /// テクスチャの登録（registerTexture:）を見張る。登録した番号とテクスチャを覚える
  static func hook(registry: FlutterTextureRegistry) {
    guard let cls: AnyClass = object_getClass(registry as AnyObject) else {
      note("hook: no class")
      return
    }
    note("hook: registry class \(NSStringFromClass(cls))")
    let key = ObjectIdentifier(cls)
    guard !hookedClasses.contains(key) else { return }
    let selector = NSSelectorFromString("registerTexture:")
    guard let method = class_getInstanceMethod(cls, selector) else {
      note("hook: registerTexture: not found")
      return
    }
    hookedClasses.insert(key)
    typealias Register = @convention(c) (AnyObject, Selector, AnyObject) -> Int64
    let original = unsafeBitCast(method_getImplementation(method), to: Register.self)
    let replacement: @convention(block) (AnyObject, AnyObject) -> Int64 = { me, texture in
      let id = original(me, selector, texture)
      if let object = texture as? NSObject {
        lock.lock()
        textures[id] = WeakTexture(object)
        lock.unlock()
      }
      note("registered \(id) \(NSStringFromClass(type(of: texture as AnyObject)))")
      return id
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
    note("hook: ok")
  }

  /// 鳴っているプレイヤーの今のコマ
  static func currentFrame() -> CVPixelBuffer? {
    guard let id = activeTextureId else {
      miss("no active id")
      return nil
    }
    lock.lock()
    let entry = textures[id]
    lock.unlock()
    guard let object = entry?.texture else {
      miss("texture \(id) unknown (known: \(textures.keys.sorted()))")
      return nil
    }
    guard let texture = object as? FlutterTexture else {
      miss("texture \(id) not FlutterTexture")
      return nil
    }
    guard let buffer = texture.copyPixelBuffer() else {
      miss("texture \(id) gave no buffer")
      return nil
    }
    return buffer.takeRetainedValue()
  }

  // MARK: 試作の調べ（Documents/pip_debug.txt に書き出す。映像が出たら消す）

  private static var lines: [String] = []
  private static var misses: [String: Int] = [:]

  static func note(_ line: String) {
    lock.lock()
    lines.append("\(Date().timeIntervalSince1970) \(line)")
    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    lock.unlock()
  }

  private static func miss(_ reason: String) {
    lock.lock()
    misses[reason, default: 0] += 1
    lock.unlock()
  }

  static func dump(_ extra: String) {
    note(extra)
    lock.lock()
    let text = (lines + misses.map { "miss x\($0.value): \($0.key)" }).joined(separator: "\n")
    lock.unlock()
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    try? text.write(to: dir.appendingPathComponent("pip_debug.txt"), atomically: true, encoding: .utf8)
  }

  /// 小窓の表示層は IOSurface 付きのバッファでないと真っ黒になるので、無ければ写し替える
  static func sampleBuffer(for frame: CVPixelBuffer) -> CMSampleBuffer? {
    let pixelBuffer = CVPixelBufferGetIOSurface(frame) != nil ? frame : surfaceCopy(of: frame)
    guard let pb = pixelBuffer else { return nil }
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format)
    guard let format = format else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample)
    return sample
  }

  private static func surfaceCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    var copy: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        CVPixelBufferGetPixelFormatType(source), attrs as CFDictionary, &copy)
    guard let target = copy else { return nil }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(target, [])
    defer {
      CVPixelBufferUnlockBaseAddress(target, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let src = CVPixelBufferGetBaseAddress(source),
          let dst = CVPixelBufferGetBaseAddress(target) else { return nil }
    let srcRow = CVPixelBufferGetBytesPerRow(source)
    let dstRow = CVPixelBufferGetBytesPerRow(target)
    let rowBytes = min(srcRow, dstRow)
    for y in 0..<height {
      memcpy(dst.advanced(by: y * dstRow), src.advanced(by: y * srcRow), rowBytes)
    }
    return target
  }
}
