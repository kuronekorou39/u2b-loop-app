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
- AB地点の色: A=#FF6B6B（赤系）, B=#4FC3F7（水色系）

## バージョン管理

- gitタグ（例: `v1.3.0`）と `pubspec.yaml` の `version:` は常に一致させる
- `+N` のようなビルド番号は使わない。セマンティックバージョニング（`major.minor.patch`）のみ
- リリース手順: pubspec.yaml の version 更新 → コミット → タグ作成 → push（タグpushでCI自動ビルド）
- **重要**: pubspec.yaml の version とタグを必ず同時に更新すること。ズレるとアプリ内アップデートチェックが毎回「更新あり」と誤判定する
- CI修正などコード変更のみのリリースでも、タグを打つ前に必ず pubspec.yaml の version をタグと一致させる
- **テスト版**（自分の端末だけで試す版）: `v1.158.0-beta.1` のようにハイフン付きで出す（pubspec も `1.158.0-beta.1`）。CI が GitHub のプレリリースにするので、ほかの人の更新確認には出ない。届くのは「テスト版も受け取る」（設定のバージョン行を 5 回タップ → 詳細設定 › デバッグ）をオンにした端末だけ。確かめて問題なければ、同じ内容を `v1.158.0` として出し直す

## ビルド

- **ローカルビルド（`flutter build` 等）は実行しない** — CI/CDで自動ビルドされるため不要
- コード変更後の確認は `flutter analyze` 程度に留める
- Gradleメモリ設定: `-Xmx4G -XX:+UseSerialGC`（Windowsの仮想メモリ断片化対策）
- APK出力先: `build/app/outputs/flutter-apk/app-release.apk`
