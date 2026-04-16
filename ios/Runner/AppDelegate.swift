import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var waveformTask: Task<Void, Never>?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      // --- Export channel ---
      let exportChannel = FlutterMethodChannel(
        name: "com.u2bloop/export",
        binaryMessenger: controller.binaryMessenger
      )
      exportChannel.setMethodCallHandler { [weak self] call, result in
        if call.method == "exportRegion" {
          self?.handleExportRegion(call: call, result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      // --- Waveform channel ---
      let waveformChannel = FlutterMethodChannel(
        name: "com.u2bloop/waveform",
        binaryMessenger: controller.binaryMessenger
      )
      waveformChannel.setMethodCallHandler { [weak self] call, result in
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
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
