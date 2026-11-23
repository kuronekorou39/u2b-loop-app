package com.u2bloop.u2b_loop_app

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File

private const val PROGRESS_POLL_MS = 400L

/**
 * 1 つの動画の複数の区間を、順につないだ 1 本にする。
 * 無変換の結合はキーフレームでしか切れないので、Transformer で区間の端を正確に切る。
 * すべてメインスレッドで呼ぶこと（Transformer の決まり）。
 */
@androidx.annotation.OptIn(UnstableApi::class)
internal class RegionJoinExporter(
    private val context: Context,
    private val onProgress: (Int) -> Unit,
    private val onFinished: (error: Throwable?) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val holder = ProgressHolder()
    private var transformer: Transformer? = null

    private val poll = object : Runnable {
        override fun run() {
            val t = transformer ?: return
            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                onProgress(holder.progress)
            }
            handler.postDelayed(this, PROGRESS_POLL_MS)
        }
    }

    fun start(inputUri: String, ranges: List<Pair<Long, Long>>, audioOnly: Boolean, output: File) {
        val uri = if (inputUri.startsWith("/")) Uri.fromFile(File(inputUri)) else Uri.parse(inputUri)
        val items = ranges.map { (startMs, endMs) ->
            val media = MediaItem.Builder()
                .setUri(uri)
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(startMs)
                        .setEndPositionMs(endMs)
                        .build()
                )
                .build()
            EditedMediaItem.Builder(media).setRemoveVideo(audioOnly).build()
        }
        val composition = Composition.Builder(EditedMediaItemSequence(items)).build()
        val t = Transformer.Builder(context)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    finish(null)
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    finish(exportException)
                }
            })
            .build()
        transformer = t
        t.start(composition, output.absolutePath)
        handler.post(poll)
    }

    /** 止める。Transformer はキャンセルでは通知しないので、呼び出し側が後始末する */
    fun cancel() {
        handler.removeCallbacks(poll)
        transformer?.cancel()
        transformer = null
    }

    private fun finish(error: Throwable?) {
        handler.removeCallbacks(poll)
        transformer = null
        onFinished(error)
    }
}
