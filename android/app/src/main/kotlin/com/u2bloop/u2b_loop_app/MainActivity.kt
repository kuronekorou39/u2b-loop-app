package com.u2bloop.u2b_loop_app

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** テンポ/キー解析用 PCM のサンプルレート（Dart 側 BpmKeyDetector.analysisSampleRate と一致させる） */
private const val ANALYSIS_SAMPLE_RATE = 11025

/** 解析に使う最大秒数。それ以降の音声は捨てる（8分で約10MB） */
private const val ANALYSIS_MAX_SECONDS = 480

class MainActivity : FlutterActivity() {
    private val WAVEFORM_CHANNEL = "com.u2bloop/waveform"
    private val PIP_CHANNEL = "com.u2bloop/pip"
    private val EXPORT_CHANNEL = "com.u2bloop/export"
    private val TAG = "WaveformExtractor"
    private val ACTION_PLAY_PAUSE = "com.u2bloop.PIP_PLAY_PAUSE"
    private val REQ_POST_NOTIFICATIONS = 4801
    private val ACTION_PREV = "com.u2bloop.PIP_PREV"
    private val ACTION_NEXT = "com.u2bloop.PIP_NEXT"
    private var isPlaylist = false
    // 未捕捉のコルーチン例外でアプリがクラッシュしないようハンドラを付与
    private val scope = CoroutineScope(
        Dispatchers.IO + SupervisorJob() +
            CoroutineExceptionHandler { _, e -> Log.e(TAG, "Uncaught coroutine error", e) }
    )

    private var currentJob: Job? = null
    @Volatile private var currentExtractor: MediaExtractor? = null
    private var pipChannel: MethodChannel? = null
    private var autoPipEnabled = false
    private var isPlaying = false
    private var pipReceiver: BroadcastReceiver? = null
    private var mediaActionReceiver: BroadcastReceiver? = null
    private var noisyReceiver: BroadcastReceiver? = null
    private var audioDeviceCallback: android.media.AudioDeviceCallback? = null
    private var pipEnteredByHint = false
    private var notificationPermissionAsked = false

    /// Android 13以降は POST_NOTIFICATIONS が未許可だと前景サービスの通知が
    /// 通知ドロワーに出ない（＝再生コントロールが使えない）ため、
    /// バックグラウンド再生を開始するタイミングで一度だけ許可を求める。
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (notificationPermissionAsked) return
        val granted = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) return
        notificationPermissionAsked = true
        try {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS
            )
        } catch (_: Exception) {}
    }

    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setActions(buildPipActions())
        }

        return builder.build()
    }

    /// アクションリスト生成（共通化）
    private fun buildPipActions(): List<RemoteAction> {
        val actions = mutableListOf<RemoteAction>()

        if (isPlaylist) {
            actions.add(RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_previous),
                "前の曲", "前の曲",
                PendingIntent.getBroadcast(this, 1,
                    Intent(ACTION_PREV).setPackage(packageName),
                    PendingIntent.FLAG_IMMUTABLE)))
        }

        val ppIcon = if (isPlaying)
            Icon.createWithResource(this, android.R.drawable.ic_media_pause)
        else
            Icon.createWithResource(this, android.R.drawable.ic_media_play)
        actions.add(RemoteAction(ppIcon, if (isPlaying) "一時停止" else "再生",
            if (isPlaying) "一時停止" else "再生",
            PendingIntent.getBroadcast(this, 0,
                Intent(ACTION_PLAY_PAUSE).setPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE)))

        if (isPlaylist) {
            actions.add(RemoteAction(
                Icon.createWithResource(this, android.R.drawable.ic_media_next),
                "次の曲", "次の曲",
                PendingIntent.getBroadcast(this, 2,
                    Intent(ACTION_NEXT).setPackage(packageName),
                    PendingIntent.FLAG_IMMUTABLE)))
        }

        return actions
    }

    /// API 31+: setAutoEnterEnabled を含む params（setPictureInPictureParams 専用）
    private fun buildPipParamsAutoEnter(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .setAutoEnterEnabled(autoPipEnabled)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setActions(buildPipActions())
        }
        return builder.build()
    }

    /// setPictureInPictureParams を呼ぶ共通メソッド（API分岐をここに集約）
    private fun applyPipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setPictureInPictureParams(buildPipParamsAutoEnter())
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPipParams())
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- PiP BroadcastReceiver ---
        pipReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    ACTION_PLAY_PAUSE -> pipChannel?.invokeMethod("onPiPAction", "playPause")
                    ACTION_PREV -> pipChannel?.invokeMethod("onPiPAction", "prev")
                    ACTION_NEXT -> pipChannel?.invokeMethod("onPiPAction", "next")
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_PREV)
            addAction(ACTION_NEXT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pipReceiver, filter)
        }

        // --- Media action from PlaybackService notification ---
        mediaActionReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == "com.u2bloop.MEDIA_ACTION") {
                    val action = intent.getStringExtra("action") ?: return
                    pipChannel?.invokeMethod("onPiPAction", action)
                }
            }
        }
        val mediaFilter = IntentFilter("com.u2bloop.MEDIA_ACTION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(mediaActionReceiver, mediaFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(mediaActionReceiver, mediaFilter)
        }

        // --- Audio becoming noisy (headphones unplugged / BT disconnected) ---
        noisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    pipChannel?.invokeMethod("onAudioNoisy", null)
                }
            }
        }
        val noisyFilter = IntentFilter(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(noisyReceiver, noisyFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(noisyReceiver, noisyFilter)
        }

        // --- Audio device change detection ---
        val audioManager = getSystemService(android.media.AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val deviceCallback = object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out android.media.AudioDeviceInfo>?) {
                    sendCurrentAudioDevice(audioManager)
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out android.media.AudioDeviceInfo>?) {
                    sendCurrentAudioDevice(audioManager)
                }
            }
            audioDeviceCallback = deviceCallback
            audioManager.registerAudioDeviceCallback(deviceCallback, null)
            sendCurrentAudioDevice(audioManager)
        }

        // --- Waveform channel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAVEFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractAmplitudes" -> {
                        val url = call.argument<String>("url")
                        // true なら波形用RMSに加えてテンポ/キー解析用のPCMも返す（Map形式）
                        val withPcm = call.argument<Boolean>("withPcm") ?: false
                        if (url == null) {
                            result.error("INVALID", "URL is null", null)
                            return@setMethodCallHandler
                        }
                        cancelCurrentExtraction()
                        currentJob = scope.launch {
                            try {
                                val extraction = extractAudioAmplitudes(url, withPcm)
                                withContext(Dispatchers.Main) {
                                    result.success(
                                        if (withPcm) extraction.toMap() else extraction.amplitudes
                                    )
                                }
                            } catch (e: CancellationException) {
                                Log.d(TAG, "Extraction cancelled")
                                withContext(Dispatchers.Main) {
                                    result.success(
                                        if (withPcm) emptyMap<String, Any?>() else intArrayOf()
                                    )
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "Extraction error: ${e.message}")
                                withContext(Dispatchers.Main) {
                                    result.error("EXTRACT_ERROR", e.message ?: "Unknown error", null)
                                }
                            }
                        }
                    }
                    "cancelExtraction" -> {
                        cancelCurrentExtraction()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // --- PiP channel ---
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pipChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPiP" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            enterPictureInPictureMode(buildPipParams())
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "setAutoPiP" -> {
                    autoPipEnabled = call.argument<Boolean>("enabled") ?: false
                    isPlaylist = call.argument<Boolean>("isPlaylist") ?: false
                    try { applyPipParams() } catch (_: Exception) {}
                    result.success(true)
                }
                "updatePiPPlayState" -> {
                    isPlaying = call.argument<Boolean>("playing") ?: false
                    try { applyPipParams() } catch (_: Exception) {}
                    result.success(true)
                }
                "startPlaybackService" -> {
                    ensureNotificationPermission()
                    val title = call.argument<String>("title") ?: "再生中"
                    val playing = call.argument<Boolean>("playing") ?: true
                    val thumbPath = call.argument<String>("thumbnailPath")
                    val intent = Intent(this, PlaybackService::class.java)
                    intent.putExtra("title", title)
                    intent.putExtra("playing", playing)
                    intent.putExtra("isPlaylist", isPlaylist)
                    if (thumbPath != null) intent.putExtra("thumbnailPath", thumbPath)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "updatePlaybackService" -> {
                    val title = call.argument<String>("title") ?: "再生中"
                    val playing = call.argument<Boolean>("playing") ?: true
                    val thumbPath = call.argument<String>("thumbnailPath")
                    val intent = Intent(this, PlaybackService::class.java)
                    intent.putExtra("title", title)
                    intent.putExtra("playing", playing)
                    intent.putExtra("isPlaylist", isPlaylist)
                    if (thumbPath != null) intent.putExtra("thumbnailPath", thumbPath)
                    startService(intent)
                    result.success(true)
                }
                "stopPlaybackService" -> {
                    stopService(Intent(this, PlaybackService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // --- Export channel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXPORT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportRegion" -> {
                        val inputUri = call.argument<String>("inputUri")
                        val startMs = call.argument<Int>("startMs")
                        val endMs = call.argument<Int>("endMs")
                        val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                        val title = call.argument<String>("title") ?: "export"

                        if (inputUri == null || startMs == null || endMs == null) {
                            result.error("INVALID", "Missing parameters", null)
                            return@setMethodCallHandler
                        }

                        scope.launch {
                            // OOM等のError（catch(Exception)では捕捉不可）も含めて捕捉し、
                            // アプリクラッシュではなくエラー結果として返す
                            try {
                                val tempPath = trimMedia(inputUri, startMs.toLong(), endMs.toLong(), audioOnly, title)
                                val tempFile = java.io.File(tempPath)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    // API 29+: MediaStoreで端末のギャラリー(フォト)/ミュージックへ直接保存
                                    val location = saveToMediaStore(tempFile, audioOnly, tempFile.name)
                                    try { tempFile.delete() } catch (_: Exception) {}
                                    withContext(Dispatchers.Main) {
                                        result.success(mapOf(
                                            "success" to true,
                                            "savedToGallery" to true,
                                            "outputPath" to location))
                                    }
                                } else {
                                    // API 28以下は書込権限が必要なため共有シートにフォールバック（Dart側で共有）
                                    withContext(Dispatchers.Main) {
                                        result.success(mapOf(
                                            "success" to true,
                                            "savedToGallery" to false,
                                            "outputPath" to tempPath))
                                    }
                                }
                            } catch (e: Throwable) {
                                Log.e("Export", "Export failed", e)
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to false, "error" to (e.message ?: e.toString())))
                                }
                            }
                        }
                    }
                    "muxVideoAudio" -> {
                        // 別々にDLした映像専用/音声専用ファイルを1つのMP4へ結合（再エンコードなし）。
                        // 高解像度(1080p等)のオフライン保存用。
                        val videoPath = call.argument<String>("videoPath")
                        val audioPath = call.argument<String>("audioPath")
                        val outputPath = call.argument<String>("outputPath")
                        if (videoPath == null || audioPath == null || outputPath == null) {
                            result.error("INVALID", "Missing parameters", null)
                            return@setMethodCallHandler
                        }
                        scope.launch {
                            try {
                                muxVideoAudio(videoPath, audioPath, outputPath)
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf(
                                        "success" to true, "outputPath" to outputPath))
                                }
                            } catch (e: Throwable) {
                                Log.e("Export", "Mux failed", e)
                                try { java.io.File(outputPath).delete() } catch (_: Exception) {}
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf(
                                        "success" to false,
                                        "error" to (e.message ?: e.toString())))
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 映像専用ファイルと音声専用ファイルを1つのMP4に結合する（remux、再エンコードなし）。
    private suspend fun muxVideoAudio(
        videoPath: String, audioPath: String, outputPath: String
    ) {
        val videoEx = MediaExtractor()
        val audioEx = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            videoEx.setDataSource(videoPath)
            audioEx.setDataSource(audioPath)

            val videoTrack = firstTrackOfType(videoEx, "video/")
            if (videoTrack < 0) throw Exception("映像トラックが見つかりません")
            val audioTrack = firstTrackOfType(audioEx, "audio/")

            java.io.File(outputPath).parentFile?.mkdirs()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outVideo = muxer.addTrack(videoEx.getTrackFormat(videoTrack))
            val outAudio = if (audioTrack >= 0)
                muxer.addTrack(audioEx.getTrackFormat(audioTrack)) else -1
            muxer.start()

            copyFullTrack(videoEx, videoTrack, muxer, outVideo)
            if (audioTrack >= 0) copyFullTrack(audioEx, audioTrack, muxer, outAudio)

            muxer.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            try { videoEx.release() } catch (_: Exception) {}
            try { audioEx.release() } catch (_: Exception) {}
        }
    }

    private fun firstTrackOfType(ex: MediaExtractor, prefix: String): Int {
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith(prefix)) return i
        }
        return -1
    }

    /// 1トラックの全サンプルをそのままmuxerへコピーする（PTSは元のまま保持）。
    private suspend fun copyFullTrack(
        ex: MediaExtractor, srcTrack: Int, muxer: MediaMuxer, dstTrack: Int
    ) {
        val format = ex.getTrackFormat(srcTrack)
        val maxInputSize = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
        var buffer = java.nio.ByteBuffer.allocate(
            (if (maxInputSize > 0) maxInputSize else 2 * 1024 * 1024)
                .coerceIn(1 * 1024 * 1024, 16 * 1024 * 1024))
        val info = MediaCodec.BufferInfo()

        ex.selectTrack(srcTrack)
        ex.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        while (true) {
            yield()
            val sampleSize = try {
                ex.readSampleData(buffer, 0)
            } catch (e: IllegalArgumentException) {
                val newCap = (buffer.capacity().toLong() * 2)
                    .coerceAtMost(64L * 1024 * 1024).toInt()
                if (newCap <= buffer.capacity()) throw e
                buffer = java.nio.ByteBuffer.allocate(newCap)
                continue
            }
            if (sampleSize < 0) break
            info.offset = 0
            info.size = sampleSize
            info.presentationTimeUs = ex.sampleTime
            info.flags = ex.sampleFlags
            muxer.writeSampleData(dstTrack, buffer, info)
            ex.advance()
        }
        ex.unselectTrack(srcTrack)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPiPChanged", isInPictureInPictureMode)
        // PiP突入直後に再生状態を再同期（autoEnter時の状態揺れを補正）
        if (isInPictureInPictureMode) {
            syncPlayState()
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!autoPipEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // API 31+: setAutoEnterEnabled がPiP突入を担当。手動enterしない。
            // 再生状態だけ同期しておく
            syncPlayState()
        } else {
            // API 26-30: 手動でPiP突入（v1.37.1と同一ロジック）
            pipEnteredByHint = true
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Exception) {}
            syncPlayState()
        }
    }

    override fun onPause() {
        super.onPause()
        // API 31+: setAutoEnterEnabled が全てのバックグラウンド遷移を処理
        // API 26-30: onUserLeaveHintで処理済みならスキップ、そうでなければ手動PiP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        if (pipEnteredByHint) {
            pipEnteredByHint = false
            return
        }
        if (autoPipEnabled
            && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            && !isInPictureInPictureMode) {
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Exception) {}
            syncPlayState()
        }
    }

    /// Flutterに再生状態を問い合わせてPiPパラメータを更新
    @Suppress("DEPRECATION")
    private fun sendCurrentAudioDevice(audioManager: android.media.AudioManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val outputs = audioManager.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
        // 優先順位: Bluetooth > 有線ヘッドホン > スピーカー
        var deviceType = "speaker"
        for (device in outputs) {
            when (device.type) {
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> {
                    deviceType = "bluetooth"
                    break
                }
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                android.media.AudioDeviceInfo.TYPE_USB_HEADSET -> {
                    deviceType = "headphones"
                }
            }
        }
        runOnUiThread {
            pipChannel?.invokeMethod("onAudioDeviceChanged", deviceType)
        }
    }

    private fun syncPlayState() {
        pipChannel?.invokeMethod("getPlayState", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                isPlaying = result as? Boolean ?: isPlaying
                try { applyPipParams() } catch (_: Exception) {}
            }
            override fun error(code: String, msg: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    private suspend fun trimMedia(
        inputUri: String, startMs: Long, endMs: Long,
        audioOnly: Boolean, title: String
    ): String {
        val safeTitle = title.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(50)
            .ifBlank { "export" }
        val ext = if (audioOnly) "m4a" else "mp4"
        // 書き出し専用ディレクトリ。共有ファイル名は basename がそのまま使われるため
        // タイムスタンプを付けずクリーンな名前にする。
        // 共有完了後の即時削除は受信側コピーとレースするため行わず、
        // 前回までの一時ファイルをここ（次回書き出し開始時）でまとめて掃除する。
        val exportDir = java.io.File(cacheDir, "exports")
        if (exportDir.exists()) {
            exportDir.listFiles()?.forEach { try { it.delete() } catch (_: Exception) {} }
        } else {
            exportDir.mkdirs()
        }
        val outputFile = java.io.File(exportDir, "$safeTitle.$ext")

        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            // setDataSource: content URI / ファイルパス / URL
            if (inputUri.startsWith("content://")) {
                extractor.setDataSource(applicationContext, android.net.Uri.parse(inputUri), null)
            } else if (inputUri.startsWith("/") || inputUri.startsWith("file://")) {
                val path = if (inputUri.startsWith("file://"))
                    inputUri.removePrefix("file://") else inputUri
                val file = java.io.File(path)
                if (!file.exists()) {
                    throw Exception(
                        "ファイルが見つかりません\n" +
                        "${file.name}\n" +
                        "キャッシュが削除された可能性があります。動画を再登録してください"
                    )
                }
                // FileInputStreamで確実にアクセス
                val fis = java.io.FileInputStream(file)
                try {
                    extractor.setDataSource(fis.fd)
                } catch (e: Exception) {
                    fis.close()
                    Log.e("Export", "setDataSource failed for local file: ${e.message}")
                    throw Exception(
                        "ファイルを読み取れません\n" +
                        "${file.name}\n" +
                        "理由: ${e.message ?: "不明なエラー"}"
                    )
                } finally {
                    try { fis.close() } catch (_: Exception) {}
                }
            } else {
                extractor.setDataSource(inputUri)
            }
            yield()

            Log.d("Export", "Track count: ${extractor.trackCount}, URI: ${inputUri.take(100)}")

            if (extractor.trackCount == 0) {
                throw Exception(
                    "この動画形式はMediaExtractorで読み取れません\n" +
                    "ファイル名: ${inputUri.substringAfterLast("/")}\n" +
                    "VP9/AV1等のコーデックは書き出し非対応です"
                )
            }

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                Log.d("Export", "Track $i: ${format.getString(MediaFormat.KEY_MIME)}")
            }

            val mx = MediaMuxer(outputFile.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mx

            val trackMap = mutableMapOf<Int, Int>()
            val startUs = startMs * 1000L
            val endUs = endMs * 1000L
            val skippedMimes = mutableListOf<String>()

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (audioOnly && !mime.startsWith("audio/")) continue
                try {
                    val muxTrack = mx.addTrack(format)
                    trackMap[i] = muxTrack
                } catch (e: Exception) {
                    Log.w("Export", "Skipping track $i ($mime): ${e.message}")
                    skippedMimes.add(mime)
                }
            }

            if (trackMap.isEmpty()) {
                val allMimes = (0 until extractor.trackCount).map {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "?"
                }
                throw Exception(
                    "この動画形式は書き出しに対応していません\n" +
                    "トラック: ${allMimes.joinToString(", ")}\n" +
                    "MP4互換のコーデック(H.264/AAC)が必要です"
                )
            }

            mx.start()

            // バッファサイズはトラックの KEY_MAX_INPUT_SIZE を基準に決定する。
            // 固定1MBだとHD動画のキーフレーム(1MB超)で readSampleData が失敗し
            // クラッシュの原因になるため、十分なサイズを確保し不足時は拡張する。
            var maxInputSize = 0
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            val initialCapacity = (if (maxInputSize > 0) maxInputSize else 2 * 1024 * 1024)
                .coerceIn(1 * 1024 * 1024, 16 * 1024 * 1024)
            var buffer = java.nio.ByteBuffer.allocate(initialCapacity)
            val bufferInfo = MediaCodec.BufferInfo()

            for ((srcTrack, dstTrack) in trackMap) {
                extractor.selectTrack(srcTrack)
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                while (true) {
                    yield()
                    val sampleSize = try {
                        extractor.readSampleData(buffer, 0)
                    } catch (e: IllegalArgumentException) {
                        // バッファ不足 → 倍増して同じサンプルを再読込（位置は進んでいない）
                        val newCap = (buffer.capacity().toLong() * 2)
                            .coerceAtMost(64L * 1024 * 1024).toInt()
                        if (newCap <= buffer.capacity()) throw e
                        buffer = java.nio.ByteBuffer.allocate(newCap)
                        continue
                    }
                    if (sampleSize < 0) break

                    val sampleTime = extractor.sampleTime
                    if (sampleTime > endUs) break

                    if (sampleTime >= startUs) {
                        bufferInfo.offset = 0
                        bufferInfo.size = sampleSize
                        bufferInfo.presentationTimeUs = sampleTime - startUs
                        bufferInfo.flags = extractor.sampleFlags
                        mx.writeSampleData(dstTrack, buffer, bufferInfo)
                    }
                    extractor.advance()
                }
                extractor.unselectTrack(srcTrack)
            }

            mx.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            extractor.release()
        }

        return outputFile.absolutePath
    }

    /// 書き出し済みファイルを MediaStore 経由で端末のギャラリー(フォト)/ミュージックへ保存する。
    /// 動画は Movies/U2BLoop（Googleフォトに表示）、音声は Music/U2BLoop に保存。
    /// 戻り値は表示用の相対パス（例: "Movies/U2BLoop/foo.mp4"）。API 29(Q)以上専用。
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private fun saveToMediaStore(
        tempFile: java.io.File, audioOnly: Boolean, displayName: String
    ): String {
        val resolver = applicationContext.contentResolver
        val mime = if (audioOnly) "audio/mp4" else "video/mp4"
        val relativePath = (if (audioOnly)
            android.os.Environment.DIRECTORY_MUSIC
        else
            android.os.Environment.DIRECTORY_MOVIES) + "/U2BLoop"
        val collection = if (audioOnly)
            android.provider.MediaStore.Audio.Media
                .getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else
            android.provider.MediaStore.Video.Media
                .getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
            put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw Exception("ギャラリーへの登録に失敗しました")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                tempFile.inputStream().use { it.copyTo(out) }
            } ?: throw Exception("出力ストリームを開けませんでした")
            val done = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, done, null, null)
        } catch (e: Throwable) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
        }
        return "$relativePath/$displayName"
    }

    private fun cancelCurrentExtraction() {
        currentJob?.cancel()
        currentJob = null
        try {
            currentExtractor?.release()
        } catch (_: Exception) {}
        currentExtractor = null
    }

    /** 波形用のRMS列と、テンポ/キー解析用に間引いたモノラルPCM（[withPcm] のときだけ） */
    private class AudioExtraction(
        val amplitudes: IntArray,
        val pcm: ByteArray?,
        val sampleRate: Int,
    ) {
        fun toMap(): Map<String, Any?> =
            mapOf("amplitudes" to amplitudes, "pcm" to pcm, "sampleRate" to sampleRate)
    }

    /**
     * インターリーブPCMをモノラル化し、箱型平均で [ANALYSIS_SAMPLE_RATE] に間引く。
     * BPM/キー解析には十分な品質で、ストリーミング中に1パスで作れる。
     */
    private class MonoDecimator(inRate: Int, private val channels: Int, maxSamples: Int) {
        private val ratio = inRate.toDouble() / ANALYSIS_SAMPLE_RATE
        private val out = ShortArray(maxSamples)
        var size = 0
            private set
        private var frameSum = 0
        private var ch = 0
        private var acc = 0.0
        private var count = 0
        private var pos = 0L
        private var next = ratio

        fun push(sample: Short) {
            frameSum += sample
            ch++
            if (ch < channels) return
            acc += frameSum.toDouble() / channels
            frameSum = 0
            ch = 0
            count++
            pos++
            if (pos >= next) {
                if (size < out.size) {
                    out[size++] = (acc / count).toInt().coerceIn(-32768, 32767).toShort()
                }
                acc = 0.0
                count = 0
                next += ratio
            }
        }

        fun toByteArray(): ByteArray {
            val buf = ByteBuffer.allocate(size * 2).order(ByteOrder.LITTLE_ENDIAN)
            buf.asShortBuffer().put(out, 0, size)
            return buf.array()
        }
    }

    private suspend fun extractAudioAmplitudes(url: String, withPcm: Boolean): AudioExtraction {
        val extractor = MediaExtractor()
        currentExtractor = extractor
        var codec: MediaCodec? = null
        val empty = AudioExtraction(intArrayOf(), null, ANALYSIS_SAMPLE_RATE)
        try {
            Log.d(TAG, "setDataSource starting...")
            extractor.setDataSource(url)
            Log.d(TAG, "setDataSource done, tracks=${extractor.trackCount}")

            yield()

            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    audioFormat = format
                    break
                }
            }
            if (audioTrackIndex == -1 || audioFormat == null) {
                Log.d(TAG, "No audio track found")
                return empty
            }
            // ラムダ内で var を参照するとスマートキャストが効かないので val に移す
            val trackFormat: MediaFormat = audioFormat

            extractor.selectTrack(audioTrackIndex)

            val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: return empty
            Log.d(TAG, "Audio track: $mime")
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(trackFormat, null, null, 0)
            codec.start()

            // デコード後のレート/ch数。INFO_OUTPUT_FORMAT_CHANGED で更新される
            var inRate = runCatching { trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) }.getOrDefault(44100)
            var channels = runCatching { trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT) }.getOrDefault(2)
            var decimator: MonoDecimator? = null

            val bufferInfo = MediaCodec.BufferInfo()
            val amplitudes = mutableListOf<Int>()
            var inputEOS = false
            var outputEOS = false
            val maxAmplitudes = 100000

            while (!outputEOS && amplitudes.size < maxAmplitudes) {
                yield()

                if (!inputEOS) {
                    val inputIndex = codec.dequeueInputBuffer(5000)
                    if (inputIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inputIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputEOS = true
                        } else {
                            codec.queueInputBuffer(
                                inputIndex, 0, sampleSize,
                                extractor.sampleTime, 0
                            )
                            extractor.advance()
                        }
                    }
                }

                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 5000)
                when {
                    outputIndex >= 0 -> {
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputEOS = true
                        }
                        if (bufferInfo.size > 0) {
                            val outputBuffer = codec.getOutputBuffer(outputIndex)!!
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            outputBuffer.order(ByteOrder.LITTLE_ENDIAN)
                            val shortBuffer = outputBuffer.asShortBuffer()

                            if (withPcm && decimator == null) {
                                decimator = MonoDecimator(
                                    inRate, channels, ANALYSIS_SAMPLE_RATE * ANALYSIS_MAX_SECONDS
                                )
                            }
                            val dec = decimator
                            var sumSquares = 0L
                            var count = 0
                            while (shortBuffer.hasRemaining()) {
                                val s = shortBuffer.get()
                                val sample = s.toLong()
                                sumSquares += sample * sample
                                count++
                                dec?.push(s)
                            }
                            val rms = if (count > 0)
                                Math.sqrt(sumSquares.toDouble() / count).toInt()
                            else 0
                            amplitudes.add(rms)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        runCatching { inRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE) }
                        runCatching { channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT) }
                    }
                    outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                }
            }

            Log.d(TAG, "Done: ${amplitudes.size} amplitudes, pcm=${decimator?.size ?: 0}")
            codec.stop()
            codec.release()
            codec = null

            return AudioExtraction(
                amplitudes.toIntArray(), decimator?.toByteArray(), ANALYSIS_SAMPLE_RATE
            )
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
            currentExtractor = null
        }
    }

    override fun onDestroy() {
        // アプリを閉じた（Backで抜けた・タスクを消した）ときは、Flutter側の
        // プレイヤーごと落ちるので前景サービスも一緒に止める。
        // 残すと再生していないのに「再生中」通知だけが居座る。
        if (isFinishing) {
            try { stopService(Intent(this, PlaybackService::class.java)) } catch (_: Exception) {}
        }
        try { unregisterReceiver(pipReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(mediaActionReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(noisyReceiver) } catch (_: Exception) {}
        val deviceCallback = audioDeviceCallback
        if (deviceCallback != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                getSystemService(android.media.AudioManager::class.java)
                    .unregisterAudioDeviceCallback(deviceCallback)
            } catch (_: Exception) {}
        }
        pipReceiver = null
        mediaActionReceiver = null
        noisyReceiver = null
        audioDeviceCallback = null
        cancelCurrentExtraction()
        scope.cancel()
        super.onDestroy()
    }
}
