package com.u2bloop.u2b_loop_app

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle

class PlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "u2b_loop_playback"
        const val NOTIFICATION_ID = 1
        const val ACTION_PLAY_PAUSE = "com.u2bloop.ACTION_PLAY_PAUSE"
        const val ACTION_PREV = "com.u2bloop.ACTION_PREV"
        const val ACTION_NEXT = "com.u2bloop.ACTION_NEXT"
    }

    private var mediaSession: MediaSessionCompat? = null
    private var isPlaying = true
    private var currentTitle = "再生中"
    private var isPlaylist = false
    private var thumbnailPath: String? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        setupMediaSession()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent が null で来るのはシステムによる再起動時だけ。
        // 再生状態は Flutter プロセス側にあり、そのプロセスは既に死んでいるので、
        // ここで startForeground すると「再生中」通知だけが復活してしまう。
        if (intent == null) {
            stopPlaybackAndSelf()
            return START_NOT_STICKY
        }

        when (intent.action) {
            ACTION_PLAY_PAUSE -> {
                // Flutter側に通知
                sendToFlutter("playPause")
                return START_NOT_STICKY
            }
            ACTION_PREV -> {
                sendToFlutter("prev")
                return START_NOT_STICKY
            }
            ACTION_NEXT -> {
                sendToFlutter("next")
                return START_NOT_STICKY
            }
        }

        // 通常の開始コマンド
        currentTitle = intent.getStringExtra("title") ?: "再生中"
        isPlaying = intent.getBooleanExtra("playing", true)
        isPlaylist = intent.getBooleanExtra("isPlaylist", false)
        intent.getStringExtra("thumbnailPath")?.let { thumbnailPath = it }

        updateNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        // START_STICKY にするとプロセスが死んだ後にシステムが intent=null で
        // 再起動し、再生していないのに通知だけが残る（アプリが生きて見える）。
        return START_NOT_STICKY
    }

    /// タスク一覧からスワイプして閉じられたとき。
    /// 再生の実体は Flutter プロセス側にあり一緒に落ちるため、
    /// サービスだけ生かしても「再生中」通知が残るだけになる。
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopPlaybackAndSelf()
        super.onTaskRemoved(rootIntent)
    }

    /// 通知を消してサービスを終了する
    private fun stopPlaybackAndSelf() {
        try { mediaSession?.isActive = false } catch (_: Exception) {}
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {}
        try {
            getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try { mediaSession?.isActive = false } catch (_: Exception) {}
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    private fun setupMediaSession() {
        mediaSession = MediaSessionCompat(this, "U2BLoop").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { sendToFlutter("playPause") }
                override fun onPause() { sendToFlutter("playPause") }
                override fun onSkipToNext() { sendToFlutter("next") }
                override fun onSkipToPrevious() { sendToFlutter("prev") }
            })
            isActive = true
        }
    }

    fun updatePlayState(playing: Boolean, title: String?, playlist: Boolean) {
        if (title != null) currentTitle = title
        isPlaying = playing
        isPlaylist = playlist
        updateNotification()
    }

    private fun updateNotification() {
        // メタデータ
        val metaBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "U2B Loop")
        // サムネイル
        thumbnailPath?.let { path ->
            try {
                val bitmap = BitmapFactory.decodeFile(path)
                if (bitmap != null) {
                    metaBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
                }
            } catch (_: Exception) {}
        }
        mediaSession?.setMetadata(metaBuilder.build())

        // 再生状態
        val state = if (isPlaying)
            PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        val actions = PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_PLAY or
                PlaybackStateCompat.ACTION_PAUSE or
                (if (isPlaylist) PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS else 0L)

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(state, 0, 1.0f)
                .setActions(actions)
                .build()
        )

        // 通知更新
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {}
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText("U2B Loop")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        // メディアスタイル（ロック画面にコントローラー表示）
        val mediaStyle = MediaStyle()
            .setMediaSession(mediaSession?.sessionToken)

        // アクションボタン
        val actionIndices = mutableListOf<Int>()
        var idx = 0

        if (isPlaylist) {
            builder.addAction(
                android.R.drawable.ic_media_previous, "前の曲",
                buildActionIntent(ACTION_PREV, 1))
            actionIndices.add(idx++)
        }

        builder.addAction(
            if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (isPlaying) "一時停止" else "再生",
            buildActionIntent(ACTION_PLAY_PAUSE, 0))
        actionIndices.add(idx++)

        if (isPlaylist) {
            builder.addAction(
                android.R.drawable.ic_media_next, "次の曲",
                buildActionIntent(ACTION_NEXT, 2))
            actionIndices.add(idx++)
        }

        mediaStyle.setShowActionsInCompactView(*actionIndices.toIntArray())
        builder.setStyle(mediaStyle)

        return builder.build()
    }

    private fun buildActionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, PlaybackService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun sendToFlutter(action: String) {
        // MainActivityのpipChannelを通じてFlutterに通知
        // Broadcastで送信し、MainActivityで受け取る
        val intent = Intent("com.u2bloop.MEDIA_ACTION")
        intent.putExtra("action", action)
        intent.setPackage(packageName)
        sendBroadcast(intent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "再生中",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "バックグラウンド再生中の通知"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
