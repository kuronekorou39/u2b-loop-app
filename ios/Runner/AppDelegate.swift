import Flutter
import UIKit
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var waveformTask: Task<Void, Never>?
  var pipManager: PiPManager?
  // チャネルをインスタンスで保持（ARC でハンドラが解除されるのを防ぐ）
  private var exportChannel: FlutterMethodChannel?
  private var waveformChannel: FlutterMethodChannel?
  private var pipChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
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
      if call.method == "exportRegion" {
        self?.handleExportRegion(call: call, result: result)
      } else {
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
        self?.startExtraction(url: url, result: result)
      case "cancelExtraction":
        self?.cancelExtraction()
        result(nil as Any?)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // --- PiP channel ---
    let pc = FlutterMethodChannel(name: "com.u2bloop/pip", binaryMessenger: messenger)
    self.pipChannel = pc
    pc.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let manager = self?.pipManager else {
        result(["error": "pipManager is nil", "hasWindow": self?.window != nil] as [String: Any])
        return
      }
      switch call.method {
      case "enterPiP":
        let args = call.arguments as? [String: Any]
        manager.updateThumbnail(
          url: args?["thumbnailUrl"] as? String,
          localPath: args?["thumbnailPath"] as? String
        )
        let diag = manager.enterPiPWithDiag()
        result(diag)
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

    // PiPManager のセットアップ（window が利用可能になった後）
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let window = self.window else { return }
      let manager = PiPManager()
      manager.setup(in: window, channel: pc)
      self.pipManager = manager
    }
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

    // Sanitize filename
    let safeTitle = String(
      title.replacingOccurrences(of: "[^a-zA-Z0-9\\p{Han}\\p{Hiragana}\\p{Katakana}_ -]",
                                  with: "",
                                  options: .regularExpression)
        .prefix(50)
    )
    let ext = audioOnly ? "m4a" : "mp4"
    let outputPath = NSTemporaryDirectory() + "\(safeTitle).\(ext)"

    // Remove existing output file
    try? FileManager.default.removeItem(atPath: outputPath)

    // Build asset URL
    let assetURL: URL
    if inputUri.hasPrefix("http://") || inputUri.hasPrefix("https://") {
      guard let url = URL(string: inputUri) else {
        result(["success": false, "error": "無効なURLです"])
        return
      }
      assetURL = url
    } else if inputUri.hasPrefix("file://") {
      guard let url = URL(string: inputUri) else {
        result(["success": false, "error": "無効なファイルパスです"])
        return
      }
      assetURL = url
    } else {
      assetURL = URL(fileURLWithPath: inputUri)
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

  // MARK: - Waveform Extraction

  private func startExtraction(url: String, result: @escaping FlutterResult) {
    waveformTask?.cancel()
    waveformTask = Task.detached { [weak self] in
      do {
        let amplitudes = try await self?.extractAudioAmplitudes(url: url) ?? []
        await MainActor.run { result(amplitudes) }
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

  private func extractAudioAmplitudes(url: String) async throws -> [Int] {
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

      var data = Data(count: length)
      data.withUnsafeMutableBytes { ptr in
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                   destination: ptr.baseAddress!)
      }

      data.withUnsafeBytes { rawBuffer in
        let samples = rawBuffer.bindMemory(to: Int16.self)
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

// MARK: - PiP Manager

class PiPManager: NSObject, AVPictureInPictureControllerDelegate,
                  AVPictureInPictureSampleBufferPlaybackDelegate {
  private var pipController: AVPictureInPictureController?
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var pipView: UIView?
  private weak var channel: FlutterMethodChannel?

  private var autoPipEnabled = false
  private(set) var isPlaying = false
  private var isPlaylist = false

  func setup(in window: UIWindow, channel: FlutterMethodChannel) {
    self.channel = channel
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

    // PiP にはアクティブな .playback オーディオセッションが必要
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)

    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    self.displayLayer = layer

    // PiP には view hierarchy に追加された layer が必要（非表示でOKだがサイズは必要）
    let view = UIView(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
    view.layer.addSublayer(layer)
    layer.frame = CGRect(x: 0, y: 0, width: 300, height: 169)
    window.rootViewController?.view.addSubview(view)
    self.pipView = view

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
      pipController!.startPictureInPicture()
      diag["ok"] = true
    }
    return diag
  }

  private func enqueueBlackFrame(width: Int, height: Int) {
    guard let layer = displayLayer else { return }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
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
    layer.flush()
    layer.enqueue(buffer)
  }

  func setAutoPiP(enabled: Bool, isPlaylist: Bool) {
    self.autoPipEnabled = enabled
    self.isPlaylist = isPlaylist
  }

  func updatePlayState(playing: Bool) {
    self.isPlaying = playing
    pipController?.invalidatePlaybackState()
  }

  /// SceneDelegate から呼ばれる: バックグラウンド遷移時の自動 PiP
  func startPiPIfNeeded() {
    guard autoPipEnabled, isPlaying,
          let pip = pipController,
          !pip.isPictureInPictureActive,
          AVPictureInPictureController.isPictureInPictureSupported() else { return }
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

  private func enqueuePosterFrame(_ image: UIImage) {
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
    channel?.invokeMethod("onPiPChanged", arguments: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    channel?.invokeMethod("onPiPChanged", arguments: false)
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
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
