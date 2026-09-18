package com.example.warningapplication_1.overlay

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import com.example.warningapplication_1.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class LockScreenWarningActivity : Activity() {
    private val timeHandler = Handler(Looper.getMainLooper())
    private val timeTicker = object : Runnable {
        override fun run() {
            updateTime()
            timeHandler.postDelayed(this, 1000L)
        }
    }

    private val unlockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_USER_PRESENT) {
                finish()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupLockScreenWindow()
        setContentView(R.layout.activity_lock_screen_warning)
        registerReceiver(unlockReceiver, IntentFilter(Intent.ACTION_USER_PRESENT))
        updateContent(intent)
        timeTicker.run()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        updateContent(intent)
    }

    private fun setupLockScreenWindow() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun updateContent(intent: Intent?) {
        findViewById<TextView>(R.id.lock_warning_title).text =
            "实时行车预警信息"
        renderWarningLines(intent?.getStringExtra(OverlayService.EXTRA_CONTENT))
        updateTime()
    }

    private fun renderWarningLines(content: String?) {
        val container = findViewById<LinearLayout>(R.id.lock_warning_list)
        container.removeAllViews()

        val lines = content
            ?.lines()
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.takeIf { it.isNotEmpty() }
            ?: defaultWarningLines()

        for (line in lines) {
            container.addView(buildWarningLine(line))
        }
    }

    private fun buildWarningLine(line: String): TextView {
        val textView = TextView(this)
        textView.textSize = 13.5f
        textView.setTextColor(Color.WHITE)
        textView.setTypeface(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
        textView.includeFontPadding = true
        textView.setPadding(0, dp(4), 0, dp(4))

        if (line.contains("：")) {
            val parts = line.split("：", limit = 2)
            val label = parts.getOrNull(0).orEmpty()
            val value = parts.getOrNull(1).orEmpty()
            val spannable = android.text.SpannableString("$label：$value")
            spannable.setSpan(
                android.text.style.ForegroundColorSpan(Color.parseColor("#48BB78")),
                0,
                label.length + 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
            spannable.setSpan(
                android.text.style.ForegroundColorSpan(Color.WHITE),
                label.length + 1,
                spannable.length,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
            textView.text = spannable
        } else {
            textView.text = line
        }

        return textView
    }

    private fun defaultWarningLines(): List<String> {
        return listOf(
            "信号强度：--",
            "车次：--",
            "方向：--",
            "线路：--",
            "机车：--",
            "里程：--",
            "速度：--"
        )
    }

    private fun updateTime() {
        findViewById<TextView>(R.id.lock_warning_date).text =
            SimpleDateFormat("yyyy年MM月dd日 EEEE", Locale.getDefault()).format(Date())
        findViewById<TextView>(R.id.lock_warning_time).text =
            SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    override fun onDestroy() {
        timeHandler.removeCallbacks(timeTicker)
        unregisterReceiver(unlockReceiver)
        super.onDestroy()
    }
}
