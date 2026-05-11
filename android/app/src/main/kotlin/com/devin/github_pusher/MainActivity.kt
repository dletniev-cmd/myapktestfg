package com.devin.github_pusher

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "github_pusher/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val name = call.argument<String>("filename")
                    val mime = call.argument<String>("mime") ?: "application/zip"
                    val srcPath = call.argument<String>("srcPath")
                    if (name == null || srcPath == null) {
                        result.error("ARG", "filename и srcPath обязательны", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val src = File(srcPath)
                        if (!src.exists()) {
                            result.error("NO_SRC", "Источник не найден: $srcPath", null)
                            return@setMethodCallHandler
                        }
                        val outPath = saveToDownloads(name, mime, src)
                        result.success(outPath)
                    } catch (e: Throwable) {
                        result.error("IO", e.message ?: "Не удалось сохранить", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(filename: String, mime: String, src: File): String {
        // Android 10+ — пишем через MediaStore.Downloads (без WRITE_EXTERNAL_STORAGE).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore.insert вернул null")
            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw IllegalStateException("Не удалось открыть OutputStream")
                src.inputStream().use { input -> input.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }

        // Android 9 и ниже — пишем напрямую в /storage/emulated/0/Download/.
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!downloads.exists()) downloads.mkdirs()
        val out = File(downloads, filename)
        FileOutputStream(out).use { o -> src.inputStream().use { it.copyTo(o) } }
        return out.absolutePath
    }
}


