package com.u2bloop.u2b_loop_app

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
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

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        setupMediaSession()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY_PAUSE -> {
                // Flutter側に通知
                sendToFlutter("playPause")
                return START_STICKY
            }
            ACTION_PREV -> {
                sendToFlutter("prev")
                return START_STICKY
            }
            ACTION_NEXT -> {
                sendToFlutter("next")
                return START_STICKY
            }
        }

        // 通常の開始コマンド
        currentTitle = intent?.getStringExtra("title") ?: "再生中"
        isPlaying = intent?.getBooleanExtra("playing", true) ?: true
        isPlaylist = intent?.getBooleanExtra("isPlaylist", false) ?: false

        updateNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mediaSession?.release()
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
        mediaSession?.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "U2B Loop")
                .build()
        )

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
