package com.example.warningapplication_1.overlay

import android.app.NotificationChannel
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.app.NotificationCompat
import com.example.warningapplication_1.MainActivity
import com.example.warningapplication_1.R

class OverlayService : Service() {
    private var windowManager: WindowManager? = null
    private var bubbleView: TextView? = null
    private var warningView: View? = null
    private var foregroundStarted = false
    private var latestTitle: String = "火车预警"
    private var latestContent: String = "等待数据..."
    private var latestTrainNo: String = ""
    private var lastValidTrainNo: String = ""
    private var bubbleColorChanged = false
    private var warningExpanded = false
    private var screenReceiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_USER_PRESENT -> refreshFloatingBubble()
                Intent.ACTION_SCREEN_ON,
                Intent.ACTION_SCREEN_OFF -> refreshFloatingBubble()
            }
        }
    }

    companion object {
        const val ACTION_SHOW = "SHOW"
        const val ACTION_HIDE = "HIDE"
        const val ACTION_UPDATE = "UPDATE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_CONTENT = "content"
        const val EXTRA_TRAIN_NO = "trainNo"
        private const val CHANNEL_ID = "overlay_service"
        private const val NOTIFICATION_ID = 2001
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        registerScreenReceiver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW -> {
                ensureForeground()
                saveContent(intent)
                refreshFloatingBubble()
            }
            ACTION_UPDATE -> {
                ensureForeground()
                saveContent(intent)
                refreshFloatingBubble()
            }
            ACTION_HIDE -> {
                removeAllOverlayViews()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refreshFloatingBubble() {
        if (isDeviceLocked()) {
            removeAllOverlayViews()
            openLockScreenWarningPage()
        } else {
            if (!warningExpanded) removeWarningCard()
            showBubble()
            updateBubble()
            updateWarningContent()
        }
    }

    private fun isDeviceLocked(): Boolean {
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        return keyguardManager.isKeyguardLocked
    }

    private fun showBubble() {
        if (bubbleView != null) return

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }

        val flags =
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE

        val params = WindowManager.LayoutParams(
            dp(58),
            dp(58),
            type,
            flags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            x = dp(16)
            y = 0
        }

        bubbleView = TextView(this).apply {
            text = "预警"
            textSize = 13f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            background = buildBubbleBackground()
            var downRawX = 0f
            var downRawY = 0f
            var startX = 0
            var startY = 0
            var moved = false
            setOnTouchListener { view, event ->
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        downRawX = event.rawX
                        downRawY = event.rawY
                        startX = params.x
                        startY = params.y
                        moved = false
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = (event.rawX - downRawX).toInt()
                        val dy = (event.rawY - downRawY).toInt()
                        if (kotlin.math.abs(dx) > dp(4) || kotlin.math.abs(dy) > dp(4)) moved = true
                        params.x = (startX - dx).coerceAtLeast(0)
                        params.y = startY + dy
                        windowManager?.updateViewLayout(view, params)
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        if (!moved) view.performClick()
                        true
                    }
                    else -> false
                }
            }
            setOnClickListener {
                warningExpanded = !warningExpanded
                if (warningExpanded) {
                    showWarningCard()
                } else {
                    removeWarningCard()
                }
            }
        }

        try {
            windowManager?.addView(bubbleView, params)
        } catch (_: Exception) {
            bubbleView = null
        }
    }

    private fun showWarningCard() {
        if (warningView != null || isDeviceLocked()) return

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }

        val flags = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            flags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP
            y = dp(50)
        }

        warningView = LayoutInflater.from(this).inflate(R.layout.overlay_warning, null)
        updateWarningContent()
        try {
            windowManager?.addView(warningView, params)
        } catch (_: Exception) {
            warningView = null
        }
    }

    private fun saveContent(intent: Intent?) {
        latestTitle = intent?.getStringExtra(EXTRA_TITLE) ?: latestTitle
        latestContent = intent?.getStringExtra(EXTRA_CONTENT) ?: latestContent
        latestTrainNo = intent?.getStringExtra(EXTRA_TRAIN_NO) ?: latestTrainNo
        updateTrainColorState(latestTrainNo)
    }

    private fun updateWarningContent() {
        warningView ?: return
        warningView?.findViewById<TextView>(R.id.overlay_content)?.text = latestContent
    }

    private fun updateBubble() {
        bubbleView?.background = buildBubbleBackground()
    }

    private fun removeWarningCard() {
        warningView?.let {
            windowManager?.removeView(it)
            warningView = null
        }
    }

    private fun removeBubble() {
        bubbleView?.let {
            windowManager?.removeView(it)
            bubbleView = null
        }
    }

    private fun removeAllOverlayViews() {
        removeWarningCard()
        removeBubble()
        warningExpanded = false
    }

    private fun updateTrainColorState(trainNo: String) {
        val normalized = trainNo.trim()
        if (normalized.isEmpty() || normalized == "#" || normalized == "--") return

        if (lastValidTrainNo.isEmpty()) {
            lastValidTrainNo = normalized
            return
        }

        if (lastValidTrainNo != normalized) {
            bubbleColorChanged = !bubbleColorChanged
            lastValidTrainNo = normalized
        }
    }

    private fun buildBubbleBackground(): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (bubbleColorChanged) Color.parseColor("#2563EB") else Color.parseColor("#DC2626"))
            setStroke(dp(2), Color.WHITE)
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun openLockScreenWarningPage() {
        val intent = Intent(this, LockScreenWarningActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_TITLE, latestTitle)
            putExtra(EXTRA_CONTENT, latestContent)
            putExtra(EXTRA_TRAIN_NO, latestTrainNo)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun ensureForeground() {
        if (foregroundStarted) return
        startForeground(NOTIFICATION_ID, buildNotification())
        foregroundStarted = true
    }

    private fun registerScreenReceiver() {
        if (screenReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(screenReceiver, filter)
        screenReceiverRegistered = true
    }

    private fun unregisterScreenReceiver() {
        if (!screenReceiverRegistered) return
        unregisterReceiver(screenReceiver)
        screenReceiverRegistered = false
    }

    private fun buildNotification(): android.app.Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "预警浮窗服务",
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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("火车预警接收中")
            .setContentText("蓝牙预警数据接收服务运行中")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        removeAllOverlayViews()
        unregisterScreenReceiver()
        super.onDestroy()
    }
}
