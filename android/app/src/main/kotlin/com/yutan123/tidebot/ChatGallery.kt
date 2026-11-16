package com.yutan123.tidebot

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Bounded, permission-scoped attachment pages; arbitrary documents use the system picker. */
internal object ChatGallery {
    private const val PAGE_SIZE = 36
    private const val MAX_FILE_BYTES = 256L * 1024 * 1024

    private fun collection(kind: String) = when (kind) {
        "img" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        "file" -> MediaStore.Files.getContentUri("external")
        else -> error("不支持的附件类型")
    }

    @Suppress("DEPRECATION")
    fun page(context: Context, offset: Int, kind: String = "img"): List<Map<String, Any>> {
        val items = mutableListOf<Map<String, Any>>()
        val collection = collection(kind)
        val projection = mutableListOf("_id", "_display_name", "_size", "mime_type")
        if (kind == "video") projection.add("duration")
        // Scoped storage returns accessible documents; use the system picker for other locations.
        val selection = if (kind == "file")
            "media_type != ${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE} AND media_type != ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO} AND _size > 0"
            else null
        context.contentResolver.query(collection, projection.toTypedArray(), selection, null,
            "date_added DESC, _id DESC")?.use { cursor ->
            if (!cursor.moveToPosition(offset.coerceAtLeast(0))) return items
            do {
                val id = cursor.getLong(0)
                val uri = ContentUris.withAppendedId(collection, id)
                val bitmap = try {
                    when {
                        kind == "file" -> null
                        Build.VERSION.SDK_INT >= 29 -> context.contentResolver.loadThumbnail(uri, Size(220, 220), null)
                        kind == "video" -> MediaStore.Video.Thumbnails.getThumbnail(
                            context.contentResolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null)
                        else -> MediaStore.Images.Thumbnails.getThumbnail(
                            context.contentResolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
                    }
                } catch (_: Exception) { null }
                val thumbnail = bitmap?.let {
                    try {
                        ByteArrayOutputStream().use { output ->
                            it.compress(Bitmap.CompressFormat.JPEG, 75, output)
                            Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
                        }
                    } finally { it.recycle() }
                }
                items.add(mapOf(
                    "id" to id.toString(),
                    "thumbnail" to (thumbnail ?: ""),
                    "name" to (cursor.getString(1) ?: "附件"),
                    "size" to cursor.getLong(2),
                    "mime" to (cursor.getString(3) ?: "application/octet-stream"),
                    "duration" to (if (kind == "video") cursor.getLong(4) else 0L)
                ))
            } while (items.size < PAGE_SIZE && cursor.moveToNext())
        }
        return items
    }

    fun importImages(context: Context, ids: List<String>, kind: String = "img"): List<String> {
        require(ids.isNotEmpty() && ids.size <= PAGE_SIZE) { "一次最多选择36个附件" }
        val collection = collection(kind)
        val folder = File(context.cacheDir, "chat_gallery/${UUID.randomUUID()}")
        check(folder.mkdirs())
        try {
            return ids.map { id ->
                val uri = ContentUris.withAppendedId(collection, id.toLong())
                var name: String? = null
                context.contentResolver.query(uri, arrayOf("_display_name", "_size"), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        name = cursor.getString(0)
                        require(cursor.getLong(1) <= MAX_FILE_BYTES) { "单个附件不能超过256 MiB" }
                    }
                }
                val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(context.contentResolver.getType(uri))
                    ?: when (kind) { "img" -> "jpg"; "video" -> "mp4"; else -> "bin" }
                val safeName = name?.substringAfterLast('/')?.substringAfterLast('\\')
                    ?.replace(Regex("[\\x00-\\x1f]"), "_")?.take(180)
                    ?.takeIf { it.isNotBlank() && it != "." && it != ".." } ?: "attachment.$extension"
                val destination = File(folder, UUID.randomUUID().toString())
                check(destination.mkdirs())
                val file = File(destination, safeName)
                val input = context.contentResolver.openInputStream(uri) ?: error("无法读取附件")
                input.use { source ->
                    file.outputStream().use { target ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val count = source.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= MAX_FILE_BYTES) { "单个附件不能超过256 MiB" }
                            target.write(buffer, 0, count)
                        }
                    }
                }
                file.absolutePath
            }
        } catch (error: Exception) {
            folder.deleteRecursively()
            throw error
        }
    }
}
