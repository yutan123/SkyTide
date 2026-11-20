package com.yutan123.skytide

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Only app-owned, date-named automatic archives enter the rotation. */
class TideAutoBackup(private val context: Context, messenger: BinaryMessenger,
    private val ready: (() -> Unit)? = null) {
    private val channel = MethodChannel(messenger, "tidebot.auto_backup")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var lockFile: RandomAccessFile? = null
    private var lock: FileLock? = null
    private val relative = "${Environment.DIRECTORY_DOWNLOADS}/SkyTide/backup/"
    private val pattern = Regex("SkyTide-backup-\\d{4}-\\d{2}-\\d{2}\\.zip")
    private val metadata = context.getSharedPreferences("auto_backup_files", Context.MODE_PRIVATE)
    private fun collection(): Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "ready") { result.success(null); ready?.invoke(); return@setMethodCallHandler }
            executor.execute {
                try {
                    val value: Any? = when (call.method) {
                        "schedule" -> {
                            val manager = WorkManager.getInstance(context)
                            if (call.argument<Boolean>("enabled") == true) {
                                val work = PeriodicWorkRequestBuilder<TideAutoBackupWorker>(12, TimeUnit.HOURS)
                                    .setConstraints(Constraints.Builder().setRequiresStorageNotLow(true).build()).build()
                                manager.enqueueUniquePeriodicWork("tidebot-auto-backup", ExistingPeriodicWorkPolicy.KEEP, work)
                            } else manager.cancelUniqueWork("tidebot-auto-backup")
                            null
                        }
                        "lock" -> {
                            if (lock != null) false else {
                                val f = RandomAccessFile(File(context.filesDir, "auto_backup.lock"), "rw")
                                val acquired = runCatching { f.channel.tryLock() }.getOrNull()
                                if (acquired == null) { f.close(); false }
                                else { lockFile = f; lock = acquired; true }
                            }
                        }
                        "unlock" -> { release(); null }
                        "list" -> list()
                        "publish" -> {
                            check(Build.VERSION.SDK_INT >= 29) { "自动备份到下载目录需要 Android 10 或更新版本" }
                            val name = requireNotNull(call.argument<String>("name"))
                            require(pattern.matches(name))
                            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            require(file.isFile && file.path.startsWith(context.cacheDir.canonicalPath + File.separator))
                            val values = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                                put(MediaStore.Downloads.MIME_TYPE, "application/zip")
                                put(MediaStore.Downloads.RELATIVE_PATH, relative)
                                put(MediaStore.Downloads.IS_PENDING, 1)
                            }
                            val previous = list().filter { it["name"] == name }
                            val uri = requireNotNull(context.contentResolver.insert(collection(), values))
                            try {
                                context.contentResolver.openOutputStream(uri, "w")!!.use { output ->
                                    file.inputStream().use { it.copyTo(output, 65536) }
                                }
                                check(context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null) > 0) { "发布自动备份失败" }
                                metadata.edit().putString(uri.toString(), JSONArray(call.argument<List<String>>("selected") ?: emptyList<String>()).toString()).commit()
                            } catch (e: Exception) {
                                context.contentResolver.delete(uri, null, null); throw e
                            }
                            previous.forEach {
                                val oldUri = it["uri"] as String
                                check(context.contentResolver.delete(Uri.parse(oldUri), null, null) > 0) { "替换当天备份失败" }
                                metadata.edit().remove(oldUri).apply()
                            }
                            check(context.contentResolver.update(uri, ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                            }, null, null) > 0) { "更新备份文件名失败" }
                            null
                        }
                        "delete" -> { remove(requireNotNull(call.argument<String>("uri"))); null }
                        "prune" -> {
                            val keep = requireNotNull(call.argument<Int>("keep")); require(keep in 1..100)
                            list().drop(keep).forEach { remove(it["uri"] as String) }; null
                        }
                        "open" -> {
                            val uri = requireNotNull(call.argument<String>("uri"))
                            require(list().any { it["uri"] == uri })
                            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(uri), "application/zip")
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)); null
                        }
                        else -> throw IllegalArgumentException("未知备份操作")
                    }
                    main.post { result.success(value) }
                } catch (e: Exception) { main.post { result.error("AUTO_BACKUP", e.message, null) } }
            }
        }
    }
    private fun list(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val rows = mutableListOf<Map<String, Any>>()
        val cols = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.SIZE,
            MediaStore.Downloads.DATE_ADDED, MediaStore.Downloads.OWNER_PACKAGE_NAME)
        context.contentResolver.query(collection(), cols,
            "${MediaStore.Downloads.RELATIVE_PATH} = ? AND ${MediaStore.Downloads.IS_PENDING} = 0", arrayOf(relative),
            "${MediaStore.Downloads.DATE_ADDED} DESC, ${MediaStore.Downloads._ID} DESC")?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1)
                if (!pattern.matches(name) || c.getString(4) != context.packageName) continue
                val uri = ContentUris.withAppendedId(collection(), c.getLong(0)).toString()
                rows.add(mapOf("uri" to uri, "name" to name, "size" to c.getLong(2), "created" to c.getLong(3) * 1000,
                    "contents" to (metadata.getString(uri, null) ?: "[]")))
            }
        }
        return rows
    }
    private fun remove(uri: String) {
        require(list().any { it["uri"] == uri }) { "仅能管理本应用的自动备份" }
        check(context.contentResolver.delete(Uri.parse(uri), null, null) > 0) { "删除备份失败" }
        metadata.edit().remove(uri).apply()
    }
    private fun release() { lock?.release(); lock = null; lockFile?.close(); lockFile = null }
    fun dispose() { channel.setMethodCallHandler(null); executor.execute { release() }; executor.shutdown() }
}

class TideAutoBackupWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val engine = FlutterEngine(applicationContext)
        val messenger = engine.dartExecutor.binaryMessenger
        val completed = CompletableDeferred<Boolean>()
        val channel = MethodChannel(messenger, "tidebot.auto_backup")
        val transfer = MethodChannel(messenger, "tidebot.data_transfer")
        transfer.setMethodCallHandler { call, result ->
            if (call.method == "freeSpace") {
                runCatching { StatFs(requireNotNull(call.argument<String>("path"))).availableBytes }
                    .fold(result::success) { result.error("STORAGE", it.message, null) }
            } else result.notImplemented()
        }
        val bridge = TideAutoBackup(applicationContext, messenger) {
            channel.invokeMethod("run", null, object : MethodChannel.Result {
                override fun success(value: Any?) { completed.complete(true) }
                override fun error(code: String, message: String?, details: Any?) { completed.complete(false) }
                override fun notImplemented() { completed.complete(false) }
            })
        }
        try {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "autoBackupMain"))
            if (withTimeout(8 * 60 * 1000L) { completed.await() }) Result.success() else Result.retry()
        } catch (_: Exception) { Result.retry() }
        finally { bridge.dispose(); transfer.setMethodCallHandler(null); engine.destroy() }
    }
}
