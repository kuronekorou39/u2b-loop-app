/// ビルドの種類。ビルドするときに `--dart-define=STORE_BUILD=true` で決まる。
///
/// App Store に出す iOS 版（ストア用）では、YouTube の曲の保存・書き出しと
/// デバッグモードを入れない（審査ガイドライン 5.2.3 / 2.3.1）。
/// 定数なので、ストア用のビルドでは使われない側のコードがアプリから取り除かれ、
/// あとから有効にする手段は残らない。自分の端末用の IPA と Android 版は全部入り
class BuildFlavor {
  BuildFlavor._();

  static const store = bool.fromEnvironment('STORE_BUILD');
}
