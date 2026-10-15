package com.aimanager.parent

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Thin Android Storage Access Framework adapter; no broad storage permission,
 * credentials, arbitrary paths or plaintext staging files are used. */
class AuditExportDocuments(private val activity: Activity) {
    companion object { const val REQUEST_CODE = 48127; const val MAX_BYTES = 8 * 1024 * 1024 }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: Reply? = null
    private var picking = false
    private var lease: Lease? = null
    private var closed = false
    private var resumed = false

    private class Lease(val id: String, val uri: Uri) {
        @Volatile var cancelled = false
        var writing = false
        var reply: Reply? = null
    }
    private inner class Reply(private val result: MethodChannel.Result) {
        private val done = AtomicBoolean(false)
        fun success(value: Any?) { main.post { if (done.compareAndSet(false, true)) result.success(value) } }
        fun error(code: String) { main.post { if (done.compareAndSet(false, true)) result.error(code, "文件保存未完成", null) } }
    }

    fun onResume() { resumed = true }
    fun onPause() {
        resumed = false
        // The picker itself is an expected external Activity. Writing plaintext
        // after the parent app leaves foreground is not an expected transition.
        if (lease?.writing == true) lease?.cancelled = true
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(result)
        if (closed) { reply.error("SAVE_UNAVAILABLE"); return }
        when (call.method) {
            "choose" -> {
                val job = call.argument<String>("jobId")
                if (job == null || !job.matches(Regex("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"))) {
                    reply.error("INVALID_DOCUMENT"); return
                }
                if (picking || lease != null || !resumed) { reply.error("SAVE_BUSY"); return }
                picker = reply
                picking = true
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, "audit-$job.json")
                    }, REQUEST_CODE)
                } catch (_: Exception) { picker = null; picking = false; reply.error("PICKER_UNAVAILABLE") }
            }
            "write" -> {
                val selected = lease
                val bytes = call.argument<ByteArray>("bytes")
                if (selected == null || selected.id != call.argument<String>("ticket") ||
                    selected.cancelled || selected.writing || !resumed || bytes == null ||
                    bytes.isEmpty() || bytes.size > MAX_BYTES) {
                    bytes?.fill(0); reply.error("INVALID_DOCUMENT"); return
                }
                selected.writing = true
                selected.reply = reply
                worker.execute {
                    var success = false
                    try {
                        if (selected.cancelled) throw IllegalStateException()
                        activity.contentResolver.openOutputStream(selected.uri, "wt").use { stream ->
                            if (stream == null) throw IllegalStateException()
                            var offset = 0
                            while (offset < bytes.size) {
                                if (selected.cancelled) throw IllegalStateException()
                                val count = minOf(32768, bytes.size - offset)
                                stream.write(bytes, offset, count)
                                offset += count
                            }
                            stream.flush()
                        }
                        success = !selected.cancelled
                    } catch (_: Exception) { /* No path, URI or document content in logs. */ }
                    finally { bytes.fill(0) }
                    val completed = success
                    main.post {
                        if (completed && !selected.cancelled && resumed && !closed) {
                            if (lease === selected) lease = null
                            reply.success(true)
                        } else {
                            selected.cancelled = true
                            // Keep writes and cleanup serialized; a cancelled stream
                            // cannot recreate the document after deletion.
                            worker.execute {
                                erase(selected.uri)
                                main.post {
                                    if (lease === selected) lease = null
                                    reply.error("SAVE_ABORTED")
                                    if (closed) worker.shutdown()
                                }
                            }
                        }
                    }
                }
            }
            "abort" -> { discard(); reply.success(null) }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val reply = picker
        picker = null
        picking = false
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { reply?.success(null); return true }
        if (uri.scheme != "content") { reply?.error("INVALID_DOCUMENT"); return true }
        if (closed || reply == null) { worker.execute { erase(uri) }; return true }
        val selected = Lease(UUID.randomUUID().toString(), uri)
        lease = selected
        reply.success(selected.id)
        return true
    }

    private fun erase(uri: Uri) {
        try { if (DocumentsContract.deleteDocument(activity.contentResolver, uri)) return } catch (_: Exception) {}
        // Some providers reject delete. Remove any partial contents where possible.
        try { activity.contentResolver.openOutputStream(uri, "wt")?.close() } catch (_: Exception) {}
    }
    private fun discard() {
        picker?.error("SAVE_ABORTED"); picker = null
        val selected = lease ?: return
        selected.cancelled = true
        if (!selected.writing) {
            worker.execute { erase(selected.uri) }
            lease = null
        }
    }
    fun close() {
        closed = true; resumed = false; discard()
        // Do not interrupt an in-flight provider write: its queued cleanup owns
        // completion. No executor work is retained across process termination.
        if (lease == null) worker.shutdown()
    }
}
