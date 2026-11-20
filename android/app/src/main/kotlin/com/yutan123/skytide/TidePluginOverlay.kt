package com.yutan123.skytide

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import android.text.TextUtils
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

internal class TidePluginOverlay(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val appOps = context.getSystemService(android.app.AppOpsManager::class.java)
    private val channel = MethodChannel(messenger, "skytide.plugin.device")
    private val watcher = android.app.AppOpsManager.OnOpChangedListener { _, _ ->
        activity.runOnUiThread { if (!allowed()) close() }
    }
    private var watching = false
    private var foreground = activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
    private var owner: String? = null
    private var panel: LinearLayout? = null
    private var web: WebView? = null
    private var session = 0L
    private var pageReady = false
    private var pendingUpdate: String? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private data class Recording(
        val id: String, val recorder: android.media.MediaRecorder,
        val file: java.io.File, val result: MethodChannel.Result,
        val finish: Runnable
    )
    private var recording: Recording? = null

    init {
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<String>("id") ?: ""
            try {
                when (call.method) {
                    "show" -> {
                        check(foreground && activity.hasWindowFocus()) { "请在 SkyTide 前台打开悬浮窗" }
                        check(allowed()) { "系统未允许悬浮窗" }
                        check(owner == null || owner == id) { "请先关闭其他插件的悬浮窗" }
                        show(id, call.argument<String>("name").orEmpty(),
                            requireNotNull(call.argument<String>("html")),
                            call.argument<Int>("width") ?: 200,
                            call.argument<Int>("height") ?: 180,
                            call.argument<String>("assets") ?: "{}",
                            call.argument<Boolean>("compact") == true)
                        result.success(true)
                    }
                    "isCurrentOverlay" -> result.success(owner == id && allowed() &&
                        call.argument<Number>("session")?.toLong() == session)
                    "update" -> {
                        check(allowed() && owner == id) { "悬浮窗未打开或授权已撤销" }
                        val data = requireNotNull(call.argument<String>("data"))
                        if (pageReady) dispatchUpdate(data) else pendingUpdate = data
                        result.success(true)
                    }
                    "close" -> { if (owner == id) close(); result.success(null) }
                    "location" -> {
                        checkForeground()
                        result.success(location())
                    }
                    "motion" -> {
                        checkForeground()
                        motion(result)
                    }
                    "microphone" -> {
                        checkForeground()
                        record(id, (call.argument<Int>("durationMs") ?: 2000).coerceIn(500, 10000), result)
                    }
                    "revoke" -> {
                        if (owner == id && call.argument<Boolean>("overlay") == true) close()
                        if (recording?.id == id && call.argument<Boolean>("microphone") == true) finishRecording(false)
                        result.success(null)
                    }
                    "checkForeground" -> { checkForeground(); result.success(true) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("PLUGIN_DEVICE", error.message, null)
            }
        }
    }

    private fun checkForeground() {
        check(foreground && activity.hasWindowFocus()) { "请在 SkyTide 前台使用设备权限" }
    }

    private fun location(): Map<String, Any>? {
        val fine = context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = context.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        check(fine || coarse) { "系统未允许位置访问" }
        val manager = context.getSystemService(LocationManager::class.java)
        val providers = if (fine) listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            else listOf(LocationManager.NETWORK_PROVIDER)
        val fix = providers.filter { manager.isProviderEnabled(it) }
            .mapNotNull { manager.getLastKnownLocation(it) }.maxByOrNull { it.elapsedRealtimeNanos } ?: return null
        return if (fine) mapOf("latitude" to fix.latitude, "longitude" to fix.longitude,
            "accuracy" to fix.accuracy, "timestamp" to fix.time)
        else mapOf("latitude" to (fix.latitude * 100).roundToInt() / 100.0,
            "longitude" to (fix.longitude * 100).roundToInt() / 100.0,
            "accuracy" to maxOf(2000f, fix.accuracy), "timestamp" to fix.time)
    }

    private fun motion(result: MethodChannel.Result) {
        val sensors = context.getSystemService(SensorManager::class.java)
        val types = mapOf(android.hardware.Sensor.TYPE_ACCELEROMETER to "acceleration",
            android.hardware.Sensor.TYPE_GYROSCOPE to "angularVelocity",
            android.hardware.Sensor.TYPE_ROTATION_VECTOR to "rotationVector")
        val values = mutableMapOf<String, Any>("screenRotation" to wm.defaultDisplay.rotation * 90)
        val listener = object : android.hardware.SensorEventListener {
            override fun onAccuracyChanged(sensor: android.hardware.Sensor, accuracy: Int) = Unit
            override fun onSensorChanged(event: android.hardware.SensorEvent) {
                val key = types[event.sensor.type] ?: return
                values.putIfAbsent(key, event.values.toList())
            }
        }
        for (type in types.keys) {
            sensors.getDefaultSensor(type)?.let { sensors.registerListener(listener, it, SensorManager.SENSOR_DELAY_NORMAL, handler) }
        }
        handler.postDelayed({
            sensors.unregisterListener(listener)
            if (foreground) result.success(values) else result.error("PLUGIN_DEVICE", "设备动作采样已取消", null)
        }, 200)
    }

    private fun record(id: String, duration: Int, result: MethodChannel.Result) {
        check(context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "系统未允许录音" }
        check(recording == null) { "已有插件正在录音" }
        val file = java.io.File.createTempFile("plugin-audio-", ".m4a", context.cacheDir)
        @Suppress("DEPRECATION")
        val recorder = if (Build.VERSION.SDK_INT >= 31) android.media.MediaRecorder(context) else android.media.MediaRecorder()
        try {
            recorder.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(android.media.MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(64000)
            recorder.setOutputFile(file.absolutePath)
            recorder.setOnErrorListener { _, _, _ -> finishRecording(false) }
            recorder.prepare()
            recorder.start()
            val finish = Runnable { finishRecording(true) }
            recording = Recording(id, recorder, file, result, finish)
            handler.postDelayed(finish, duration.toLong())
        } catch (error: Exception) {
            runCatching { recorder.release() }
            file.delete()
            throw error
        }
    }

    private fun finishRecording(deliver: Boolean) {
        val active = recording ?: return
        recording = null
        handler.removeCallbacks(active.finish)
        val stopped = runCatching { active.recorder.stop() }.isSuccess
        runCatching { active.recorder.release() }
        try {
            if (!deliver || !stopped || !foreground || active.file.length() !in 1L..262144L) {
                active.result.error("PLUGIN_DEVICE", "录音已取消或失败", null)
            } else {
                val data = android.util.Base64.encodeToString(active.file.readBytes(), android.util.Base64.NO_WRAP)
                active.result.success(mapOf("mimeType" to "audio/mp4", "base64" to data))
            }
        } catch (error: Exception) {
            active.result.error("PLUGIN_DEVICE", error.message, null)
        } finally {
            active.file.delete()
        }
    }

    fun resume() { foreground = true; if (!allowed()) close() }
    fun pause() { foreground = false; finishRecording(false) }
    fun dispose() { pause(); channel.setMethodCallHandler(null); close() }
    private fun allowed() = Build.VERSION.SDK_INT >= 26 && Settings.canDrawOverlays(context)
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density).roundToInt()

    private fun dispatchUpdate(data: String) {
        val json = org.json.JSONObject.quote(data)
        web?.evaluateJavascript("window.dispatchEvent(new CustomEvent('tideoverlayupdate',{detail:JSON.parse($json)}));", null)
    }

    private fun show(id: String, name: String, html: String, width: Int, height: Int, assets: String, compact: Boolean) {
        check(Build.VERSION.SDK_INT >= 26)
        close()
        val windowSession = ++session
        val metrics = context.resources.displayMetrics
        val w = dp(width.coerceIn(96, 320)).coerceAtMost((metrics.widthPixels * .8).toInt())
        val h = dp(height.coerceIn(64, 320)).coerceAtMost((metrics.heightPixels * .65).toInt())
        val barHeight = dp(if (compact) 36 else 40)
        val params = WindowManager.LayoutParams(w, h + barHeight,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_SECURE,
            PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            x = (metrics.widthPixels - w - dp(12)).coerceAtLeast(0)
            y = dp(72)
        }
        val root = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val bar = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(0xff20352e.toInt())
            }
        }
        val title = TextView(context).apply {
            text = if (compact) "↔" else "SkyTide · ${name.take(48)}"
            contentDescription = "移动 SkyTide 悬浮窗：${name.take(48)}"
            setTextColor(Color.WHITE)
            textSize = 12f
            setPadding(dp(8), 0, 0, 0)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val dismiss = TextView(context).apply {
            text = "×"
            textSize = 24f
            contentDescription = "关闭悬浮窗"
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setOnClickListener { close() }
        }
        var x = 0; var y = 0; var startX = 0f; var startY = 0f
        title.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { x = params.x; y = params.y; startX = event.rawX; startY = event.rawY; true }
                MotionEvent.ACTION_MOVE -> {
                    val display = context.resources.displayMetrics
                    params.x = (x + (event.rawX - startX).roundToInt()).coerceIn(0, (display.widthPixels - w).coerceAtLeast(0))
                    params.y = (y + (event.rawY - startY).roundToInt()).coerceIn(0, (display.heightPixels - params.height).coerceAtLeast(0))
                    try { wm.updateViewLayout(root, params) } catch (_: IllegalArgumentException) { close() }
                    true
                }
                else -> true
            }
        }
        bar.addView(title, if (compact) LinearLayout.LayoutParams(dp(36), barHeight)
            else LinearLayout.LayoutParams(0, barHeight, 1f))
        title.gravity = if (compact) Gravity.CENTER else Gravity.CENTER_VERTICAL
        if (compact) title.setPadding(0, 0, 0, 0)
        bar.addView(dismiss, LinearLayout.LayoutParams(barHeight, barHeight))
        root.addView(bar, LinearLayout.LayoutParams(if (compact) -2 else -1, barHeight).apply {
            gravity = Gravity.END
        })
        val view = WebView(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            settings.apply {
                javaScriptEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                blockNetworkLoads = true
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
            }
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    if (web !== view || session != windowSession) return
                    pageReady = true
                    pendingUpdate?.let { dispatchUpdate(it) }
                    pendingUpdate = null
                }
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                    if (request.url.scheme == "data" || request.url.scheme == "blob") null
                    else WebResourceResponse("text/plain", "UTF-8", null)
                override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                    if (web === view) close()
                    return true
                }
            }
        }
        val inFlight = java.util.concurrent.atomic.AtomicBoolean(false)
        var lastMessage = -100L
        view.addJavascriptInterface(object {
            @android.webkit.JavascriptInterface
            fun send(json: String?) {
                if (json == null || json.length > 32768 || !inFlight.compareAndSet(false, true)) return
                handler.post {
                    val now = android.os.SystemClock.uptimeMillis()
                    if (web !== view || session != windowSession || !allowed() ||
                        now - lastMessage < 100 || json.toByteArray(Charsets.UTF_8).size > 32768) {
                        inFlight.set(false)
                        return@post
                    }
                    lastMessage = now
                    channel.invokeMethod("overlayMessage", mapOf("id" to id, "session" to windowSession, "json" to json),
                        object : MethodChannel.Result {
                            override fun success(result: Any?) { inFlight.set(false) }
                            override fun error(code: String, message: String?, details: Any?) { inFlight.set(false) }
                            override fun notImplemented() { inFlight.set(false) }
                        })
                }
            }
        }, "TideOverlayBridge")
        root.addView(view, LinearLayout.LayoutParams(-1, h))
        owner = id; panel = root; web = view
        try {
            appOps.startWatchingMode(android.app.AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, context.packageName, watcher)
            watching = true
            wm.addView(root, params)
            val assetJson = org.json.JSONObject.quote(assets).replace("<", "\\u003c")
            val bootstrap = """<script>(()=>{const a=JSON.parse($assetJson); const bridge=window.TideOverlayBridge; Object.defineProperty(window,'TideOverlay',{value:Object.freeze({asset:p=>Object.prototype.hasOwnProperty.call(a,p)?a[p]:null,postMessage:d=>bridge.send(JSON.stringify(d))})});})();</script>"""
            view.loadDataWithBaseURL(null, """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; form-action 'none'; base-uri 'none'">$bootstrap$html""", "text/html", "UTF-8", null)
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    private fun close() {
        if (watching) { watching = false; appOps.stopWatchingMode(watcher) }
        val root = panel
        val view = web
        owner = null; panel = null; web = null
        pageReady = false
        pendingUpdate = null
        if (root != null) {
            if (root.isAttachedToWindow) runCatching { wm.removeViewImmediate(root) }
            if (view != null) root.removeView(view)
        }
        view?.destroy()
    }
}
