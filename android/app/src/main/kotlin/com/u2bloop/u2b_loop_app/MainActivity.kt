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
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val WAVEFORM_CHANNEL = "com.u2bloop/waveform"
    private val PIP_CHANNEL = "com.u2bloop/pip"
    private val EXPORT_CHANNEL = "com.u2bloop/export"
    private val TAG = "WaveformExtractor"
    private val ACTION_PLAY_PAUSE = "com.u2bloop.PIP_PLAY_PAUSE"
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var currentJob: Job? = null
    @Volatile private var currentExtractor: MediaExtractor? = null
    private var pipChannel: MethodChannel? = null
    private var autoPipEnabled = false
    private var isPlaying = false
    private var pipReceiver: BroadcastReceiver? = null
    private var pipEnteredByHint = false

    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))

        // API 31+: アプリがバックグラウンドに移行する際に自動でPiPに入る
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoPipEnabled)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = PendingIntent.getBroadcast(
                this, 0,
                Intent(ACTION_PLAY_PAUSE).setPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE
            )
            val icon = if (isPlaying)
                Icon.createWithResource(this, android.R.drawable.ic_media_pause)
            else
                Icon.createWithResource(this, android.R.drawable.ic_media_play)
            val title = if (isPlaying) "一時停止" else "再生"
            builder.setActions(listOf(RemoteAction(icon, title, title, intent)))
        }

        return builder.build()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- PiP BroadcastReceiver ---
        pipReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_PLAY_PAUSE) {
                    pipChannel?.invokeMethod("onPiPAction", "playPause")
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, IntentFilter(ACTION_PLAY_PAUSE), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pipReceiver, IntentFilter(ACTION_PLAY_PAUSE))
        }

        // --- Waveform channel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAVEFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractAmplitudes" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("INVALID", "URL is null", null)
                            return@setMethodCallHandler
                        }
                        cancelCurrentExtraction()
                        currentJob = scope.launch {
                            try {
                                val amplitudes = extractAudioAmplitudes(url)
                                withContext(Dispatchers.Main) {
                                    result.success(amplitudes)
                                }
                            } catch (e: CancellationException) {
                                Log.d(TAG, "Extraction cancelled")
                                withContext(Dispatchers.Main) {
                                    result.success(intArrayOf())
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
                    // API 31+: autoEnterEnabled を即反映
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            setPictureInPictureParams(buildPipParams())
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "updatePiPPlayState" -> {
                    isPlaying = call.argument<Boolean>("playing") ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        setPictureInPictureParams(buildPipParams())
                    }
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
                            try {
                                val outputPath = trimMedia(inputUri, startMs.toLong(), endMs.toLong(), audioOnly, title)
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to true, "outputPath" to outputPath))
                                }
                            } catch (e: Exception) {
                                Log.e("Export", "Export failed: ${e.message}")
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to false, "error" to (e.message ?: "Unknown error")))
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPiPChanged", isInPictureInPictureMode)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pipEnteredByHint = true
            // まず現在の状態で即座にPiPに入る
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Exception) {}
            // その後Flutterに正確な状態を問い合わせてパラメータを更新
            pipChannel?.invokeMethod("getPlayState", null, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    isPlaying = result as? Boolean ?: isPlaying
                    try {
                        setPictureInPictureParams(buildPipParams())
                    } catch (_: Exception) {}
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    override fun onPause() {
        super.onPause()
        // onUserLeaveHintで既にPiP処理済みならスキップ（二重呼び出し防止）
        if (pipEnteredByHint) {
            pipEnteredByHint = false
            return
        }
        // タスク一覧から別アプリ切替時のPiP対応
        if (autoPipEnabled
            && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            && !isInPictureInPictureMode) {
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Exception) {}
            // 再生状態を同期
            pipChannel?.invokeMethod("getPlayState", null, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    isPlaying = result as? Boolean ?: isPlaying
                    try {
                        setPictureInPictureParams(buildPipParams())
                    } catch (_: Exception) {}
                }
                override fun error(code: String, msg: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    private suspend fun trimMedia(
        inputUri: String, startMs: Long, endMs: Long,
        audioOnly: Boolean, title: String
    ): String {
        val safeTitle = title.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(50)
        val ext = if (audioOnly) "m4a" else "mp4"
        val outputFile = java.io.File(cacheDir, "export_${safeTitle}_${System.currentTimeMillis()}.$ext")

        val extractor = MediaExtractor()
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
                } finally {
                    fis.close()
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

            val muxer = MediaMuxer(outputFile.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val trackMap = mutableMapOf<Int, Int>()
            val startUs = startMs * 1000L
            val endUs = endMs * 1000L
            val skippedMimes = mutableListOf<String>()

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (audioOnly && !mime.startsWith("audio/")) continue
                try {
                    val muxTrack = muxer.addTrack(format)
                    trackMap[i] = muxTrack
                } catch (e: Exception) {
                    Log.w("Export", "Skipping track $i ($mime): ${e.message}")
                    skippedMimes.add(mime)
                }
            }

            if (trackMap.isEmpty()) {
                muxer.release()
                val allMimes = (0 until extractor.trackCount).map {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "?"
                }
                throw Exception(
                    "この動画形式は書き出しに対応していません\n" +
                    "トラック: ${allMimes.joinToString(", ")}\n" +
                    "MP4互換のコーデック(H.264/AAC)が必要です"
                )
            }

            muxer.start()

            val buffer = java.nio.ByteBuffer.allocate(1024 * 1024) // 1MB
            val bufferInfo = MediaCodec.BufferInfo()

            for ((srcTrack, dstTrack) in trackMap) {
                extractor.selectTrack(srcTrack)
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                while (true) {
                    yield()
                    val sampleSize = extractor.readSampleData(buffer, 0)
                    if (sampleSize < 0) break

                    val sampleTime = extractor.sampleTime
                    if (sampleTime > endUs) break

                    if (sampleTime >= startUs) {
                        bufferInfo.offset = 0
                        bufferInfo.size = sampleSize
                        bufferInfo.presentationTimeUs = sampleTime - startUs
                        bufferInfo.flags = extractor.sampleFlags
                        muxer.writeSampleData(dstTrack, buffer, bufferInfo)
                    }
                    extractor.advance()
                }
                extractor.unselectTrack(srcTrack)
            }

            muxer.stop()
            muxer.release()
        } finally {
            extractor.release()
        }

        return outputFile.absolutePath
    }

    private fun cancelCurrentExtraction() {
        currentJob?.cancel()
        currentJob = null
        try {
            currentExtractor?.release()
        } catch (_: Exception) {}
        currentExtractor = null
    }

    private suspend fun extractAudioAmplitudes(url: String): IntArray {
        val extractor = MediaExtractor()
        currentExtractor = extractor
        var codec: MediaCodec? = null
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
                return intArrayOf()
            }

            extractor.selectTrack(audioTrackIndex)

            val mime = audioFormat.getString(MediaFormat.KEY_MIME) ?: return intArrayOf()
            Log.d(TAG, "Audio track: $mime")
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(audioFormat, null, null, 0)
            codec.start()

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

                            var sumSquares = 0L
                            var count = 0
                            while (shortBuffer.hasRemaining()) {
                                val sample = shortBuffer.get().toLong()
                                sumSquares += sample * sample
                                count++
                            }
                            val rms = if (count > 0)
                                Math.sqrt(sumSquares.toDouble() / count).toInt()
                            else 0
                            amplitudes.add(rms)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
                    outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {}
                }
            }

            Log.d(TAG, "Done: ${amplitudes.size} amplitudes")
            codec.stop()
            codec.release()
            codec = null

            return amplitudes.toIntArray()
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
            currentExtractor = null
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(pipReceiver) } catch (_: Exception) {}
        cancelCurrentExtraction()
        scope.cancel()
        super.onDestroy()
    }
}
