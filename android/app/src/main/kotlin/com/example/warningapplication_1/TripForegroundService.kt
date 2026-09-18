package com.example.warningapplication_1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/// 行程记录前台服务。
///
/// 仅用于保活进程，使 GPS 位置流在后台不被系统杀死。
/// 服务本身不直接访问位置数据——位置更新由 MainActivity 的 LocationManager 负责。
class TripForegroundService : Service() {

    companion object {
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        const val EXTRA_TRIP_NAME = "tripName"
        private const val CHANNEL_ID = "trip_service"
        private const val NOTIFICATION_ID = 2002
    }

    private var tripName = "行程记录"

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                tripName = intent.getStringExtra(EXTRA_TRIP_NAME) ?: "行程记录"
                startForegroundCompat()
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                // 显式停止时不重启
                return START_NOT_STICKY
            }
            null -> {
                // 服务被系统杀死后自动重启（intent 为 null）
                // 重新显示通知保活，等待 Flutter 端恢复行程
                startForegroundCompat()
            }
        }
        // 被系统杀死后自动重启，防止进程消亡导致白屏
        return START_STICKY
    }

    private fun startForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "行程记录服务",
                NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }

        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(tripName)
            .setContentText("行程记录中…")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ 需要指定 foregroundServiceType
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
