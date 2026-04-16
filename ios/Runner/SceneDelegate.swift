import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    // バックグラウンド遷移時: autoPiP が有効なら PiP を開始
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    appDelegate.pipManager?.startPiPIfNeeded()
  }
}
