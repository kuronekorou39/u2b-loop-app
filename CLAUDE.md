# U2B Loop App

YouTubeとローカル動画のAB区間ループ再生アプリ（Flutter/Android）。

## 開発ルール

- 個人利用・APK配布（ストア非公開）
- YouTube規約は気にしない（個人利用のため）
- まずAndroid、将来iOS対応
- 状態管理は Riverpod を使う
- 動画再生は media_kit を使う
- YouTube URL抽出は youtube_explode_dart を使う
- UIのカラーはWebアプリ版に揃える（ダーク: bg=#1A1A2E, accent=#4ECCA3/#E94560）
- AB地点の色: A=#FF6B6B（赤系）, B=#4ECCA3（緑系）

## バージョン管理

- gitタグ（例: `v1.3.0`）と `pubspec.yaml` の `version:` は常に一致させる
- `+N` のようなビルド番号は使わない。セマンティックバージョニング（`major.minor.patch`）のみ
- リリース手順: pubspec.yaml の version 更新 → コミット → タグ作成 → push（タグpushでCI自動ビルド）
- **重要**: pubspec.yaml の version とタグを必ず同時に更新すること。ズレるとアプリ内アップデートチェックが毎回「更新あり」と誤判定する
- CI修正などコード変更のみのリリースでも、タグを打つ前に必ず pubspec.yaml の version をタグと一致させる

## ビルド

- **ローカルビルド（`flutter build` 等）は実行しない** — CI/CDで自動ビルドされるため不要
- コード変更後の確認は `flutter analyze` 程度に留める
- Gradleメモリ設定: `-Xmx4G -XX:+UseSerialGC`（Windowsの仮想メモリ断片化対策）
- APK出力先: `build/app/outputs/flutter-apk/app-release.apk`
