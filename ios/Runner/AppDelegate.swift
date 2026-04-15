import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
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
    let preset = audioOnly
      ? AVAssetExportSession.Preset.appleM4A
      : AVAssetExportSession.Preset.passthrough

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset.rawValue) else {
      result(["success": false, "error": "エクスポートセッションを作成できません"])
      return
    }

    exportSession.outputURL = URL(fileURLWithPath: outputPath)
    exportSession.outputFileType = audioOnly ? .m4a : .mp4
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
}
