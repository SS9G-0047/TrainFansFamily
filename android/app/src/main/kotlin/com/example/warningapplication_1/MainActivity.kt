package com.example.warningapplication_1

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.example.warningapplication_1.overlay.OverlayService

class MainActivity : FlutterActivity() {
    private val overlayChannel = "com.example.warningapplication_1/overlay"
    private val ttsChannel = "com.example.warningapplication_1/tts"
    private val imageChannel = "com.example.warningapplication_1/native_images"
    private val locationStreamChannel = "com.example.warningapplication_1/location_stream"
    private val takePhotoRequestCode = 8102
    private val imagePermissionRequestCode = 8103
    private val cameraPermissionRequestCode = 8104

    // 实时位置流
    private var streamLocationManager: LocationManager? = null
    private var streamLocationListener: LocationListener? = null
    private var streamEventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // 音频拼接播放队列
    private var audioQueue: MutableList<String> = mutableListOf()
    private var audioPlayer: MediaPlayer? = null
    private var beepPlayer: MediaPlayer? = null

    // 图片权限请求的挂起结果
    private var pendingImagePermissionResult: MethodChannel.Result? = null
    private var pendingCameraPermissionResult: MethodChannel.Result? = null

    // 拍照的挂起结果和文件路径
    private var pendingTakePhotoResult: MethodChannel.Result? = null
    private var pendingPhotoPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
        )
        super.onCreate(savedInstanceState)
        window.decorView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
    }

    override fun onPostResume() {
        super.onPostResume()
        window.decorView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupOverlayChannel(flutterEngine)
        setupTtsChannel(flutterEngine)
        setupImageChannel(flutterEngine)
        setupLocationStreamChannel(flutterEngine)
    }

    // region Overlay 通道

    private fun setupOverlayChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showOverlay" -> {
                        val title = call.argument<String>("title") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        val trainNo = call.argument<String>("trainNo") ?: ""
                        val intent = Intent(this, OverlayService::class.java).apply {
                            action = OverlayService.ACTION_SHOW
                            putExtra(OverlayService.EXTRA_TITLE, title)
                            putExtra(OverlayService.EXTRA_CONTENT, content)
                            putExtra(OverlayService.EXTRA_TRAIN_NO, trainNo)
                        }
                        startOverlayService(intent)
                        result.success(null)
                    }
                    "updateOverlay" -> {
                        val title = call.argument<String>("title") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        val trainNo = call.argument<String>("trainNo") ?: ""
                        val intent = Intent(this, OverlayService::class.java).apply {
                            action = OverlayService.ACTION_UPDATE
                            putExtra(OverlayService.EXTRA_TITLE, title)
                            putExtra(OverlayService.EXTRA_CONTENT, content)
                            putExtra(OverlayService.EXTRA_TRAIN_NO, trainNo)
                        }
                        startOverlayService(intent)
                        result.success(null)
                    }
                    "hideOverlay" -> {
                        val intent = Intent(this, OverlayService::class.java).apply {
                            action = OverlayService.ACTION_HIDE
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "canDrawOverlays" -> {
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Settings.canDrawOverlays(this)
                            } else true
                        )
                    }
                    "openOverlaySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    "getCurrentLocation" -> {
                        val location = getCurrentLocation()
                        if (location == null) {
                            result.success(null)
                        } else {
                            result.success(
                                mapOf(
                                    "latitude" to location.latitude,
                                    "longitude" to location.longitude
                                )
                            )
                        }
                    }
                    "startTripForeground" -> {
                        val tripName = call.argument<String>("tripName") ?: "行程记录"
                        startTripForeground(tripName)
                        result.success(null)
                    }
                    "stopTripForeground" -> {
                        stopTripForeground()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // endregion

    // region 音频拼接通道

    private fun setupTtsChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speakWarning" -> {
                        val direction = call.argument<String>("direction") ?: ""
                        val trainNo = call.argument<String>("trainNo") ?: ""
                        speakWarning(direction, trainNo)
                        result.success(null)
                    }
                    "stopSpeak" -> {
                        stopSpeak()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 播放嘟嘟嘟蜂鸣音，然后按顺序拼接播放：方向 → 列车 → 接近。
    /// 上行=男声(male_*)，下行=女声(female_*)。
    /// 使用 setNextMediaPlayer 实现音频间无缝衔接。
    private fun speakWarning(direction: String, trainNo: String) {
        stopSpeak()

        // 构建播放队列（蜂鸣音作为队列首个元素）
        val isUp = direction.trim() == "上" || direction.trim() == "上行"
        val isDown = direction.trim() == "下" || direction.trim() == "下行"
        val prefix = if (isUp) "male_" else if (isDown) "female_" else "male_"

        audioQueue.clear()
        audioQueue.add("beep_warning")
        if (isUp) audioQueue.add("male_up")
        else if (isDown) audioQueue.add("female_down")
        audioQueue.add("${prefix}train")
        audioQueue.add("${prefix}approach")

        playAudioQueue()
    }

    /// 创建并 prepare 一个 MediaPlayer。
    private fun createPlayer(resId: Int): MediaPlayer? {
        return try {
            val afd = resources.openRawResourceFd(resId)
            val player = MediaPlayer()
            player.setAudioStreamType(AudioManager.STREAM_RING)
            player.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            player.prepare()
            player
        } catch (_: Exception) {
            null
        }
    }

    /// 播放音频队列首个资源，并通过 setNextMediaPlayer 预加载下一个实现无缝衔接。
    private fun playAudioQueue() {
        if (audioQueue.isEmpty()) return
        val resName = audioQueue.removeAt(0)
        val resId = resources.getIdentifier(resName, "raw", packageName)
        if (resId == 0) {
            playAudioQueue()
            return
        }
        val player = createPlayer(resId)
        if (player == null) {
            playAudioQueue()
            return
        }
        audioPlayer = player
        linkNextPlayer(player)
        player.start()
    }

    /// 为当前播放器预加载下一个音频并链接，实现无缝衔接。
    private fun linkNextPlayer(current: MediaPlayer) {
        while (audioQueue.isNotEmpty()) {
            val resName = audioQueue.removeAt(0)
            val resId = resources.getIdentifier(resName, "raw", packageName)
            if (resId == 0) continue
            val next = createPlayer(resId)
            if (next == null) continue
            current.setNextMediaPlayer(next)
            current.setOnCompletionListener { mp ->
                mp.release()
                audioPlayer = next
                linkNextPlayer(next)
            }
            current.setOnErrorListener { mp, _, _ ->
                mp.release()
                next.release()
                audioPlayer = null
                playAudioQueue()
                true
            }
            return
        }
        // 队列已空，最后一个播放器播完即结束
        current.setOnCompletionListener { mp ->
            mp.release()
            audioPlayer = null
        }
        current.setOnErrorListener { mp, _, _ ->
            mp.release()
            audioPlayer = null
            true
        }
    }

    private fun stopSpeak() {
        try {
            beepPlayer?.let { mp ->
                if (mp.isPlaying) { try { mp.stop() } catch (_: Exception) {} }
                mp.release()
            }
        } catch (_: Exception) {}
        beepPlayer = null

        try {
            audioPlayer?.let { mp ->
                if (mp.isPlaying) { try { mp.stop() } catch (_: Exception) {} }
                mp.release()
            }
        } catch (_: Exception) {}
        audioPlayer = null
        audioQueue.clear()
    }

    // endregion

    // region Image 通道

    private fun setupImageChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, imageChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestImagePermission" -> handleImagePermission(result)
                    "requestCameraPermission" -> handleCameraPermission(result)
                    "listGalleryImages" -> {
                        val limit = call.argument<Int>("limit") ?: 500
                        val offset = call.argument<Int>("offset") ?: 0
                        result.success(listGalleryImages(limit, offset))
                    }
                    "copyImageToAppData" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val path = copyImageToAppData(uri)
                        if (path != null) {
                            result.success(path)
                        } else {
                            result.error("COPY_FAILED", "无法复制图片到应用数据", null)
                        }
                    }
                    "takePhotoToAppData" -> takePhotoToAppData(result)
                    "getThumbnailPath" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        result.success(getThumbnailPath(uri))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleImagePermission(result: MethodChannel.Result) {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingImagePermissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(permission), imagePermissionRequestCode)
    }

    private fun handleCameraPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingCameraPermissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), cameraPermissionRequestCode)
    }

    private fun listGalleryImages(limit: Int, offset: Int): List<Map<String, Any?>> {
        val images = mutableListOf<Map<String, Any?>>()
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATA,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT
        )
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC LIMIT $limit OFFSET $offset"
        try {
            contentResolver.query(collection, projection, null, null, sortOrder)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
                val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
                val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val uri = ContentUris.withAppendedId(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                    ).toString()
                    val path = cursor.getString(dataCol) ?: ""
                    images.add(mapOf(
                        "id" to id.toString(),
                        "uri" to uri,
                        "path" to path,
                        "name" to (cursor.getString(nameCol) ?: ""),
                        "dateAdded" to cursor.getLong(dateCol),
                        "size" to cursor.getLong(sizeCol),
                        "width" to cursor.getInt(widthCol),
                        "height" to cursor.getInt(heightCol)
                    ))
                }
            }
        } catch (_: Exception) {}
        return images
    }

    private fun copyImageToAppData(uriString: String): String? {
        return try {
            val uri = Uri.parse(uriString)
            val dir = File(filesDir, "camera_positions").apply { mkdirs() }
            val displayName = getDisplayName(uri)
            val safeName = displayName.ifBlank { "image_${System.currentTimeMillis()}" }
                .replace(Regex("[^A-Za-z0-9._\\u4e00-\\u9fa5-]"), "_")
            val dest = File(dir, safeName)
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(dest).use { output -> input.copyTo(output) }
            } ?: return null
            dest.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun getThumbnailPath(uriString: String): String? {
        return try {
            val uri = Uri.parse(uriString)
            val thumbDir = File(cacheDir, "thumbnails").apply { mkdirs() }
            val cacheKey = uri.lastPathSegment ?: uri.toString().hashCode().toString()
            val thumbFile = File(thumbDir, "${cacheKey}_thumb.jpg")
            if (thumbFile.exists() && thumbFile.length() > 0) return thumbFile.absolutePath

            val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentResolver.loadThumbnail(uri, android.util.Size(256, 256), null)
            } else {
                val id = ContentUris.parseId(uri)
                MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver, id,
                    MediaStore.Images.Thumbnails.MINI_KIND, null
                )
            } ?: return null

            FileOutputStream(thumbFile).use { out ->
                bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
            }
            thumbFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun takePhotoToAppData(result: MethodChannel.Result) {
        if (pendingTakePhotoResult != null) {
            result.error("CAMERA_BUSY", "正在拍照，请先完成当前操作", null)
            return
        }
        try {
            val dir = File(filesDir, "camera_positions").apply { mkdirs() }
            val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.CHINA).format(Date())
            val photoFile = File(dir, "photo_$timeStamp.jpg")
            val photoUri = FileProvider.getUriForFile(
                this,
                "${packageName}.fileprovider",
                photoFile
            )
            pendingTakePhotoResult = result
            pendingPhotoPath = photoFile.absolutePath
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, photoUri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            startActivityForResult(intent, takePhotoRequestCode)
        } catch (e: Exception) {
            pendingTakePhotoResult = null
            pendingPhotoPath = null
            result.error("CAMERA_FAILED", e.message, null)
        }
    }

    // endregion

    // region 电池优化

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (isIgnoringBatteryOptimizations()) return
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    // endregion

    // region Overlay 服务

    private fun startOverlayService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // endregion

    // region 行程前台服务

    private fun startTripForeground(tripName: String) {
        val intent = Intent(this, TripForegroundService::class.java).apply {
            action = TripForegroundService.ACTION_START
            putExtra(TripForegroundService.EXTRA_TRIP_NAME, tripName)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopTripForeground() {
        val intent = Intent(this, TripForegroundService::class.java).apply {
            action = TripForegroundService.ACTION_STOP
        }
        startService(intent)
    }

    // endregion

    // region 定位

    private fun getCurrentLocation(): Location? {
        val fineGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineGranted && !coarseGranted) return null

        val locationManager = getSystemService(LOCATION_SERVICE) as LocationManager
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        return providers.mapNotNull { provider ->
            try {
                if (locationManager.isProviderEnabled(provider)) {
                    locationManager.getLastKnownLocation(provider)
                } else null
            } catch (_: Exception) { null }
        }.maxByOrNull { it.time }
    }

    // endregion

    // region 实时位置流

    private fun setupLocationStreamChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, locationStreamChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    streamEventSink = events
                    startStreamLocationUpdates()
                }

                override fun onCancel(arguments: Any?) {
                    stopStreamLocationUpdates()
                    streamEventSink = null
                }
            })
    }

    private fun startStreamLocationUpdates() {
        val fineGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineGranted && !coarseGranted) {
            mainHandler.post {
                streamEventSink?.error("PERMISSION_DENIED", "定位权限未授予", null)
            }
            return
        }

        stopStreamLocationUpdates()

        streamLocationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        // 立即发送上次已知位置，避免长时间转圈等待 GPS 首次定位
        sendLastKnownLocation()

        streamLocationListener = LocationListener { location ->
            val speedKmh = if (location.hasSpeed()) location.speed * 3.6 else 0.0
            // 使用系统当前时间而非 GPS fix 时间，确保时间戳单调递增
            val now = System.currentTimeMillis()
            mainHandler.post {
                streamEventSink?.success(
                    mapOf(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "speed" to speedKmh,
                        "timestamp" to now,
                        "stale" to false
                    )
                )
            }
        }

        try {
            // 同时监听 GPS 和 NETWORK 提供者：
            // NETWORK 通过基站/WiFi 快速定位（1-3 秒），
            // GPS 提供精确位置但冷启动慢（30 秒+）。
            var anyProviderStarted = false
            if (streamLocationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true) {
                streamLocationManager?.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    1000L,
                    0f,
                    streamLocationListener!!
                )
                anyProviderStarted = true
            }
            if (streamLocationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true) {
                streamLocationManager?.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    1000L,
                    0f,
                    streamLocationListener!!
                )
                anyProviderStarted = true
            }
            if (!anyProviderStarted) {
                mainHandler.post {
                    streamEventSink?.error("NO_PROVIDER", "GPS 和网络定位均不可用，请检查设置", null)
                }
            }
        } catch (e: SecurityException) {
            mainHandler.post {
                streamEventSink?.error("SECURITY_EXCEPTION", e.message, null)
            }
        }
    }

    /// 立即获取并发送上次已知位置，让地图快速显示初始坐标。
    private fun sendLastKnownLocation() {
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        val lastKnown = providers.mapNotNull { provider ->
            try {
                if (streamLocationManager?.isProviderEnabled(provider) == true) {
                    streamLocationManager?.getLastKnownLocation(provider)
                } else null
            } catch (_: Exception) { null }
        }.maxByOrNull { it.time }

        if (lastKnown != null) {
            val speedKmh = if (lastKnown.hasSpeed()) lastKnown.speed * 3.6 else 0.0
            val now = System.currentTimeMillis()
            mainHandler.post {
                streamEventSink?.success(
                    mapOf(
                        "latitude" to lastKnown.latitude,
                        "longitude" to lastKnown.longitude,
                        "speed" to speedKmh,
                        "timestamp" to now,
                        "stale" to true
                    )
                )
            }
        }
    }

    private fun stopStreamLocationUpdates() {
        streamLocationListener?.let { listener ->
            try {
                streamLocationManager?.removeUpdates(listener)
            } catch (_: Exception) {}
        }
        streamLocationListener = null
        streamLocationManager = null
    }

    // endregion

    // region Activity Result

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            takePhotoRequestCode -> handleTakePhotoResult(resultCode)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            imagePermissionRequestCode -> {
                val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingImagePermissionResult?.success(granted)
                pendingImagePermissionResult = null
            }
            cameraPermissionRequestCode -> {
                val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingCameraPermissionResult?.success(granted)
                pendingCameraPermissionResult = null
            }
        }
    }

    private fun handleTakePhotoResult(resultCode: Int) {
        val result = pendingTakePhotoResult ?: return
        val path = pendingPhotoPath
        pendingTakePhotoResult = null
        pendingPhotoPath = null
        if (resultCode != RESULT_OK || path == null) {
            result.success(null)
            return
        }
        val file = File(path)
        if (file.exists() && file.length() > 0) {
            result.success(path)
        } else {
            result.success(null)
        }
    }

    // endregion

    // region 工具方法

    private fun getDisplayName(uri: Uri): String {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && cursor.moveToFirst()) {
                    cursor.getString(nameIndex) ?: "自定义提示音"
                } else "自定义提示音"
            } ?: "自定义提示音"
        } catch (_: Exception) { "自定义提示音" }
    }

    // endregion

    override fun onDestroy() {
        stopSpeak()
        stopStreamLocationUpdates()
        stopTripForeground()
        streamEventSink = null
        super.onDestroy()
    }
}
