import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // AppDelegate の window は nil のままなので、PiP にはシーンの window を渡す
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
          let window = self.window else { return }
    appDelegate.attachPiP(window: window)
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    // バックグラウンド遷移時: autoPiP が有効なら PiP を開始
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    appDelegate.pipManager?.startPiPIfNeeded()
  }
}
