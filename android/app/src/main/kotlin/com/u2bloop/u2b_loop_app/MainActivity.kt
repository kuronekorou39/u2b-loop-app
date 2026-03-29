package com.u2bloop.u2b_loop_app

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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
    private val TAG = "WaveformExtractor"
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var currentJob: Job? = null
    @Volatile private var currentExtractor: MediaExtractor? = null
    private var pipChannel: MethodChannel? = null
    private var autoPipEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(16, 9))
                                .build()
                            enterPictureInPictureMode(params)
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
                    result.success(true)
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
            try {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build()
                enterPictureInPictureMode(params)
            } catch (_: Exception) {}
        }
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
        cancelCurrentExtraction()
        scope.cancel()
        super.onDestroy()
    }
}
