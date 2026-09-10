# プロジェクト全体監査レポート

- 実施日: 2026-06-12
- 対象: v1.60.7（commit cebd916）時点の全コード — lib/ 58ファイル（約19,000行）、android/ ネイティブKotlin、.github/workflows/、ドキュメント
- 方法: `flutter analyze`（lib/はクリーン）＋ 領域別の全行精読 ＋ 横断grepスキャン。重要度「高」はコードで裏取り済み

## その後の対応状況（2026-09-11 時点）

このレポートは2026-06-12時点のスナップショット。**§1〜§6 の指摘はすべて解消済み。**

- **§1 高優先バグ7件** — 修正済み（commit 93583f1）
- **§2 中程度のバグ** — 全件修正済み（v1.65.0 / v1.67.0）。
  ネイティブのreceiver・muxer解放漏れ、POST_NOTIFICATIONSのランタイム要求欠落、
  バックアップのthumbnailItemId欠落、delete()のprovider未通知、invokeMethodの非同期エラー、
  ロード成功時のタイムアウトタイマー未キャンセル、音量正規化のRMS（平方根なし）、
  フェードが正規化音量を上書き、_autoAdvanceの遅延リトライ多重予約、区間ID衝突、
  PiP復帰時の古いminiState、effectiveRegionsの副作用、波形一時ファイル名の衝突、
  プレイリストのスキップ設定が全区間選択に化ける、dispose済みcontroller参照、
  保存ボタンが出ない（detail/editor）、Heroタグ重複、取り込み時の二重pop、
  歌詞オーバーレイの追従停止、build中の副作用
- **§3 重複コード** — 全項目解消。
  遷移エンジン → `providers/playlist_engine.dart`、
  読み込み/波形パイプライン → `WaveformService.generateForVideoSource` / `prefetchAudio`、
  書き出し → `services/export_runner.dart`、
  URL解決 → `YouTubeService.pickStreamUrl` / `resolveStreamUrl`、
  名前入力・削除確認ダイアログ → `core/ui/app_dialogs.dart`、
  サムネイル → `widgets/item_thumbnail.dart`、
  AB編集UI → `widgets/loop/ab_edit_controls.dart`、
  innertubeクライアント情報 → `services/youtube_client_info.dart`、
  MethodChannel → `core/native_channels.dart`
- **§4 記述の不統一** — 全項目解消。
  テーマ色 → `AppTheme` 定数（B地点の色の規約違反も修正）、
  SnackBar → `core/ui/app_snack_bar.dart`（用途別5種）、
  ID生成 → `core/utils/id_generator.dart`、
  Hive box名・設定キー → `core/storage/app_boxes.dart`、
  sourceType → `LoopItem.isYouTube` / `isLocal`、
  `'--:--'` → `TimeUtils.formatShortMs`、
  書き込み経路 → 再生カウントもNotifier経由に統一
- **§5 デッドコード** — 削除済み（v1.65.0）
- **§6 CI・ドキュメント** — バージョン一致ガード・`flutter analyze`・`flutter test` を
  check ジョブに追加、iOS依存を分離（署名なしIPAの失敗でAPKリリースが止まらない）。
  ISSUES.md / README.md も実態に更新

**その後に足したもの**: 端末不要のユニットテスト94件（`test/`）。
以前は実機必須の integration_test が1本あるだけだった。

---

## 総評

基礎衛生は良好 — `flutter analyze`クリーン、TODO/ignoreコメント0件、`withValues`新API完全移行、永続化はHive一本、dispose処理も概ね丁寧、Flutter⇔Kotlinのメソッドチャネル名も完全一致。一方で、実害のあるバグが7件、そして巨大画面ファイルへのコピペ増殖（エクスポート処理90行×2、名前入力ダイアログ×12、テーマ色直書き約26箇所など）が主な負債。特に「プレイリスト遷移エンジンの2重実装」は重複が実バグを直接生んでいる。

---

## 1. 実害バグ（高優先）

**※ 以下7件は監査同日（2026-06-12）にすべて修正済み。**

✅=コードで直接検証済み

1. ✅ **編集→再生でプレイヤー画面が即閉じる** — `lib/screens/detail_screen.dart:88-93`
   `_openPlayer`が`_save(item)`をawaitせずに呼んでからpushするが、`_save`は末尾で`Navigator.pop()`する（:64）。awaitで`_save`が中断→PlayerScreenがpush→保存完了後のpopが**PlayerScreenを閉じる**。タイトル/メモ編集→保存せず再生、という日常操作で発生。`_openAbEditor`と`_duplicateItem`は「popしない保存」をインライン実装して回避しており、`_openPlayer`だけ誤用。

2. ✅ **一時停止の意図が強制再生で上書きされる** — `lib/screens/player_screen.dart:252-276`
   バックグラウンド中に通知/PiPコントロールから一時停止（`onPiPAction: 'playPause'`）またはヘッドホン抜きで自動停止（`onAudioNoisy`）しても`_wasPlayingBeforePause`がリセットされず、アプリ復帰時に`play()`が強制実行される。

3. ✅ **サムネイル復元の進捗ダイアログが設定画面を巻き込んで閉じる** — `lib/screens/settings_screen.dart:262-330`
   `barrierDismissible: false`はバリアタップしか防がず、Android戻るボタンでダイアログは閉じられる（PopScope未使用）。先に閉じた状態で`repairThumbnails`が完了すると、:329の`Navigator.pop(context)`が設定画面自体をpopする。インポート直後に自動実行される長時間処理なので遭遇しやすい。

4. ✅ **ミニプレイヤーのトラック遷移で旧プレイヤーが止まらない（二重再生）** — `lib/screens/player_screen.dart:2583-2593`
   ミニプレイヤー用クロージャ版`swapToPreloaded`は、PlayerScreen版`_swapToPreloaded`（:1144-1147）が行う`oldPlayer.stop()`と`relistenCompleted()`を両方省いている。スワップ後、次のプリロードが旧プレイヤーを再openするまで（YouTube解決で数秒、次曲がなければ永久に）二重再生になり、completed購読も旧プレイヤーに残る。

5. ✅ **波形リトライのバックオフ・上限が機能せず無限リトライ** — `lib/widgets/loop/loop_seekbar.dart:86-124`
   リトライ発火→親の`_generateWaveform`が冒頭でエラーをクリア→buildの「エラー消滅＝成功」判定（:119-124）が`_retryCount=0`にリセット→再失敗時はまたカウント0から。恒常的に失敗する状況では3秒ごとに「マニフェスト取得＋音声DL」を繰り返す。また`onRetryWaveform`未指定（editor_screen.dart:867）でもタイマーが起動し、偽の「再取得中...」表示が固着する。

6. **再生速度が前の曲から引き継がれる** — `lib/screens/player_screen.dart:654-713, 1024-1026, 1326-1328`
   プレイヤーA/Bを使い回す設計なのに、`setRate`は`speed != 1.0`のときしか呼ばれず、`_directLoadTrack`（前曲・トラック選択経路）とミニプレイヤー版には速度設定自体がない。speed=1.5の曲の後にspeed=1.0の曲が同じプレイヤーに載ると1.5倍速のまま再生される。

7. **completed購読のre-listen漏れ** — `lib/providers/loop_provider.dart:51-60` + `lib/screens/player_screen.dart:216`
   `relistenCompleted()`はスワップ時の1箇所でしか呼ばれず、initStateで`activeSlot`をAにリセットする経路では呼ばれない。前回セッションがスロットBで終わると、新セッションのplayerAの`completed`イベントを検知できない。ISSUES.md #1「動画非表示で次曲に進まない」の構造的な再発要因の有力候補。

## 2. 中程度のバグ

### 再生まわり（player_screen.dart）
- `:506-518` ロード成功時に30秒タイムアウトタイマーが未キャンセル → 30秒後に次曲プリロードを誤って破棄
- `:1953-1973` 音量正規化の「RMS」計算に平方根がなく平均二乗のまま比較 → 過剰補正でclamp張り付き。さらに`_startFadeIn`（:850-866）が完了時に音量100へ上書きし正規化と競合
- `:443-450` `onTrackEnd`多重発火＋`_autoAdvance`の遅延再帰にガードがなく、二重スキップしうる
- `:289-292` フルスクリーン中にバックジェスチャーでpopすると画面向き制限（横固定）が復元されない
- `:317-356` PiP復帰ハンドラがdispose時にキャプチャした古い`miniState`を使い、ミニプレイヤーでトラックが進んだ後だと古い曲に巻き戻る
- `:4049-4054` 区間IDが`'${item.id}_r${regions.length}'`形式 → 削除後の追加でID衝突（プレイリストの区間選択が壊れる）。`_addRegion`（:1610）はepoch msで安全、という不統一

### データ層
- `settings_screen.dart:64-72` バックアップJSONに`Playlist.thumbnailItemId`が欠落 → エクスポート→インポートでサムネ設定が静かに消える（Hive adapterはfield 6で保存しており非対称）
- `data_provider.dart:66-80` `delete()`がプレイリストをbox直書きで修正するが`playlistsProvider`に通知せず、開いている画面が古いまま
- `loop_item.dart:81-94` `effectiveRegions` getterに副作用（読むだけで`regions.add`が走り、後続saveで永続化）。player_screen.dart:1592に「この罠を踏んだ」形跡のコメントがあり、レガシーAB値の手動同期が3画面に分散
- `waveform_service.dart:200-229` 波形音声DLの一時ファイル名が固定（`u2b_waveform_audio.tmp`）で、素早い曲切替時に並行DLが同一ファイルに書き込み合う。`fileName`引数は存在するのに利用ゼロ

### 画面
- `playlist_detail_screen.dart:854-860` 「スキップ」設定（空リスト）のアイテムは、区間編集シートを開いて保存するだけで「全区間選択」に化ける
- `playlist_detail_screen.dart:652-657` 並べ替えがフィルタ済みリストのインデックスを`itemIds.removeAt()`に直接使用 → 孤児ID混入時に別の曲が動く
- `editor_screen.dart:529-530` A>Bのまま書き出すと正規化されずネイティブ側で必ず失敗（確認ダイアログは`.abs()`表示なので原因が見えない）
- `editor_screen.dart:605-619` 速度のみ変更しても`rateProvider`をwatchしていないため保存ボタンが出ない。detail_screenも同様にTextFieldに`onChanged`がなく保存ボタンが出現しない（`detail_screen.dart:297-303`）
- `detail_screen.dart:608-618` `dispose()`済みcontrollerから`.text`を読んでいる（現状偶然動くがAPI契約違反）
- `list_screen.dart:2286-2289` Hero tag `'thumb_${item.id}'`が同一画面内で重複しうる（同じ曲をサムネにしたプレイリストが2つあるとdebugビルドでクラッシュ）
- `list_screen.dart:452-460` `_importPlaylist`のcatch節が進捗ダイアログpop後の例外で二重popしうる

### 横断パターン
- **`invokeMethod`を同期try-catchで囲んでも非同期エラーは捕捉されない** — `app.dart:83-85,117-119` / `mini_player.dart:87-90` / `player_screen.dart:300-302,366` 他に蔓延。`.catchError((_){})`が正解
- `lyrics_overlay.dart:35-45` 歌詞の自動スクロールがGlobalKey+`ensureVisible`方式のため、ABループのB→Aジャンプで現在行が画面外に飛ぶと追従が止まり復帰しない

### ネイティブ（MainActivity.kt / PlaybackService.kt）
- `MainActivity.kt:139-167` `mediaActionReceiver`/`noisyReceiver`がローカル変数のままregisterされ、onDestroyで解除されるのは`pipReceiver`のみ。`registerAudioDeviceCallback`も解除なし → Activity再生成のたび蓄積
- `MainActivity.kt:494-578` `muxer.start()`以降の例外経路で`muxer.release()`が呼ばれない
- `AndroidManifest.xml:5` `POST_NOTIFICATIONS`宣言ありだがランタイム要求コードがlib/に皆無（targetSdk≥33では通常通知が出ない可能性）

## 3. 重複コード（規模順）

1. **プレイリスト遷移エンジンの2重実装** — PlayerScreen版（`player_screen.dart:382-1171`）とミニプレイヤー用クロージャ版（`:2517-2673`）。高バグ4・6・7はすべて重複側の欠落が原因
2. **読み込み/波形パイプライン約200行** — `editor_screen.dart:210-428` ≒ `player_screen.dart:1175-1323,1906-2009`。タイムアウト有無（60秒/なし）等の差分が既に発生
3. **`_executeExport`約90行×2** — `editor_screen.dart:516-603` ≒ `player_screen.dart:1804-1897`。ファイル名サニタイズ正規表現は`MainActivity.kt:428`にもあり計3箇所
4. **YouTubeストリームURL解決（muxed→videoOnlyフォールバック）が4箇所** — `player_screen.dart:668-679, 977-991, 1253-1261, 2547-2555`。同等機能の`youtube_service.getVideoSource`は未使用で放置
5. **名前入力ダイアログ×12箇所/6ファイル**、**削除確認ダイアログ×5箇所**、**`_buildThumbnail`×4画面**（うち`playlist_detail_screen.dart:945/1413`は同一ファイル内で完全コピペ）
6. **AB編集UI約120行** — 縦レイアウトと横ドロワーでコピペ（`player_screen.dart:3033-3157` vs `:3608-3746`）。微差が既に発生
7. 細かい重複: ANDROIDクライアント情報（clientVersion/UA）×3箇所（youtube_service/subtitle_service）、`MethodChannel('com.u2bloop/pip')`×3箇所、QR閾値2000×2箇所、音声DL処理（player_screen↔waveform_service）、`'--:--'`×16箇所

## 4. 統一されていない記述

- **テーマ色の直書き約26箇所**: `#4ECCA3`×16（cassette_animation内だけで8回、perf_overlay、tag.dart等）、`#1A1A2E`×3、`#E94560`×2など。`app_theme.dart`自身もdarkテーマ内でstatic定数と同値のローカルconstを再定義（:119-122）
- **CLAUDE.md規約違反**: コンパクトシークバーのBマーカーとAB区間塗りが緑`#4ECCA3`直書き（`loop_seekbar.dart:709,742`）。規約はB=`#4FC3F7`で、メインシークバーは準拠 → 画面によってB地点の色が違う
- **SnackBar 42箇所**すべて生呼び出しでヘルパーなし。durationが未指定/1s/2s/3s/4s/5s/8s/30sの8種に分散（例:「URLをコピーしました」が画面によって1秒と4秒）
- **ID生成3方式**: 衝突対策付き`_generateId()`（microseconds+カウンタ）があるのに、素の`millisecondsSinceEpoch`×7箇所、`microsecondsSinceEpoch`×2箇所が併存
- **ソース種別の二重表現**: `String sourceType`（'youtube'/'local'、39箇所で文字列比較）と`VideoSourceType` enum
- **Hive box名のベタ書き40箇所超**（'loop_items'等）
- **書き込み経路の混在**: Notifier経由（updatedAt更新）とbox直書き（非更新）が混在し、「再生しただけ/サムネDL完了順でリストの並びが変わる」不規則な挙動の原因に
- mountedチェック・controller disposeタイミング・エラー処理方針（throw vs silent null）が箇所ごとにバラバラ

## 5. 変なもの・デッドコード

- **`_TagManagerSheet`約160行が完全未使用** — `list_screen.dart:2486-2647`（タブ移行済みの残骸）
- **未使用API群**: `youtube_service.getVideoSource`、`waveform_service.generateFromStream`（sinkリーク内包）、`data_provider.addLocalFile`/`_generateLocalThumbnail`、`playlist_player_provider.peekNext`/`enabledCount`、`share_service.canFitInQr`/`estimateUrlLength`、`TimeUtils.parse`/nullable系4メンバー、`video_source.audioUri`フィールド
- `settings_screen.dart:839` — `_selected == LoadingAnimationType.off || _selected == null && false` の`&& false`は恒偽の死式（実験の消し残り）
- `player_screen.dart:1738-1744` — `'PiP exception: $e'`を8秒表示する英語SnackBar（v1.60.4「PiPデバッグSnackBar削除」の消し残りの疑い）
- `list_screen.dart:1677` — `top: compact ? null : null`（両分岐null）
- `player_screen.dart:3360-3376` — build中の副作用（`_isFullscreen`等のフィールド直接代入、`SystemChrome`呼び出し、Timer起動）。PiP表示乱れ（ISSUES.md #2）の温床
- `loop_provider.dart:57`等にdebugPrint残骸5箇所、`PlaybackService.kt:90-95`の`updatePlayState()`死コード
- ~~PiPチャネルに渡す`thumbnailUrl/Path`はKotlin側が読まない残骸~~ → **訂正（2026-06-12）**: iOS側`PiPManager.updateThumbnail`（AppDelegate.swift）が使用しており残骸ではない

## 6. CI・ドキュメント

- **`release.yml`にバージョン一致ガードがない** — CLAUDE.md自身が最重要注意事項とする「pubspecとタグのズレ」を防ぐCIチェックが存在しない。タグpush時に`grep -q "^version: ${TAG#v}$" pubspec.yaml`で落とす1ステップで根絶可能
- **iOSビルドがAndroidリリースを人質に** — `release` jobが`needs: [build-android, build-ios]`のため、署名なしIPA（実機配布不可）のビルド失敗でAPKリリースが止まる
- CIに`flutter analyze`ステップとキャッシュ（`subosito/flutter-action`の`cache: true`）なし
- **ISSUES.mdが陳腐化** — 修正コミットaca1b85（v1.51.0）で追加されたきり未更新。未解決リストに見えるが実態は修正済み記録。ただし#1（relisten漏れ）と#2（build中副作用＋サイズ閾値判定）には構造的な再発要因が残っている
- README.md:26「AB区間の音声を書き出し」は古い（現在はMP4動画＋ギャラリー保存対応）。integration_testにanalyze警告18件（未使用import、非推奨`debugState`×16）

---

## 推奨する対応順

1. 高バグ7件の修正（§1）— 特に1〜5は再現条件が日常操作
2. 共通化とバグ修正をセットで: 遷移エンジン統合（バグ4・6・7が同時解消）、エクスポート/波形パイプライン/URL解決の共通化
3. 進行中のデザインシステム統一リファクタに追加: 色直書き26箇所、SnackBarヘルパー、名前入力/削除確認ダイアログ共通化、`'--:--'`ヘルパー
4. CIにバージョン一致ガード＋analyzeステップ追加、iOS依存の分離
5. 掃除: `_TagManagerSheet`等のデッドコード削除、ISSUES.mdのステータス整理、ネイティブreceiver解除の対応
