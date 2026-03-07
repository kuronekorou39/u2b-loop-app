# U2B Loop App

YouTubeとローカル動画のAB区間ループ再生アプリ（Flutter/Android）。
既存Webアプリ（C:\projects\u2b-loop）を参考に作成。

## 開発ルール

- 個人利用・APK配布（ストア非公開）
- YouTube規約は気にしない（個人利用のため）
- まずAndroid、将来iOS対応
- 状態管理は Riverpod を使う
- 動画再生は media_kit を使う
- YouTube URL抽出は youtube_explode_dart を使う
- UIのカラーはWebアプリ版に揃える（ダーク: bg=#1A1A2E, accent=#4ECCA3/#E94560）
- AB地点の色: A=#FF6B6B（赤系）, B=#4ECCA3（緑系）

## ビルド

- Gradleメモリ設定: `-Xmx4G -XX:+UseSerialGC`（Windowsの仮想メモリ断片化対策）
- APK出力先: `build/app/outputs/flutter-apk/app-release.apk`
