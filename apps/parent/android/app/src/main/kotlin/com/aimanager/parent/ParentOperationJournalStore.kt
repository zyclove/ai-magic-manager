package com.aimanager.parent

import android.content.ContentValues
import android.content.Context
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypted, process-safe CAS journal. No sensitive request is stored in preferences. */
class ParentOperationJournalStore(context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.aimanager.parent/operation-journal")
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private val closing = AtomicBoolean(false)
    private val helper = Database(context.applicationContext)

    init {
        channel.setMethodCallHandler { call, result ->
            if (closing.get()) {
                result.error("JOURNAL_UNAVAILABLE", "本机核对存储不可用，已停止操作。", null)
            } else if (call.method !in setOf("read", "reserve", "replace", "finish", "digest", "list")) {
                result.notImplemented()
            } else {
                val arguments = call.arguments as? Map<*, *>
                executor.execute {
                    try {
                        val value = execute(call.method, arguments ?: error("arguments"))
                        handler.post { result.success(value) }
                    } catch (_: Exception) {
                        // Neither request content nor platform exception details cross the channel.
                        handler.post { result.error("JOURNAL_UNAVAILABLE", "本机核对记录未确认落盘，请重新打开核对。", null) }
                    }
                }
            }
        }
    }

    private class Database(context: Context) : SQLiteOpenHelper(context,
        File(context.noBackupFilesDir, "parent-operation-journal-v1.db").absolutePath, null, 1,
        DatabaseErrorHandler { throw SQLiteDatabaseCorruptException("Operation journal is unavailable") }) {
        override fun onConfigure(db: SQLiteDatabase) {
            db.execSQL("PRAGMA busy_timeout=5000")
            db.execSQL("PRAGMA secure_delete=ON")
            db.execSQL("PRAGMA synchronous=FULL")
            db.rawQuery("PRAGMA journal_mode=DELETE", null).use {
                check(it.moveToFirst() && it.getString(0).equals("delete", ignoreCase = true))
            }
        }
        override fun onCreate(db: SQLiteDatabase) {
            // A surviving key is an initialization witness. A missing database
            // must not silently become an empty slot after an uncertain write.
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            check(!store.containsAlias(keyAlias))
            db.execSQL("CREATE TABLE pending(namespace TEXT PRIMARY KEY NOT NULL, request_digest TEXT NOT NULL, record TEXT NOT NULL, collection_digest TEXT)")
            db.execSQL("CREATE INDEX pending_collection ON pending(collection_digest)")
            db.execSQL("CREATE TABLE closed(namespace TEXT NOT NULL, request_digest TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY(namespace,request_digest))")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            error("Unsupported journal schema")
        }
    }

    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun key(db: SQLiteDatabase): SecretKey = synchronized(keyLock) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(keyAlias, null)
        if (existing is SecretKey) return@synchronized existing
        // A lost key must never be mistaken for an empty journal.
        db.rawQuery("SELECT (SELECT COUNT(*) FROM pending)+(SELECT COUNT(*) FROM closed)", null).use {
            check(it.moveToFirst() && it.getLong(0) == 0L)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        generator.generateKey()
    }

    private fun encrypt(db: SQLiteDatabase, value: String, aad: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(db))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun decrypt(db: SQLiteDatabase, value: String, aad: String): String {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        check(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(db), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }

    private fun envelope(wire: String): JSONObject {
        check(wire.toByteArray(Charsets.UTF_8).size <= 4 * 1024 * 1024)
        val row = JSONObject(wire)
        check(row.length() == 5 && row.get("schema") is Int && row.getInt("schema") == 1 && row.has("terminal"))
        val id = row.getString("requestId")
        check(id.isNotBlank() && id.length <= 128)
        check(row.get("knownSuccessful") is Boolean)
        check(row.isNull("terminal") || row.getString("terminal") in setOf("EXPIRED", "ERASED"))
        val payload = JSONObject(row.getString("payload"))
        val payloadId = if (payload.optString("kind") == "cancel") "cancel:${payload.getString("jobId")}" else
            if (payload.has("requestId")) payload.getString("requestId") else payload.getString("idempotencyKey")
        check(payloadId == id)
        return row
    }

    private fun pending(db: SQLiteDatabase, namespace: String): String? {
        db.query("pending", arrayOf("request_digest", "record"), "namespace=?", arrayOf(namespace), null, null, null).use {
            if (!it.moveToFirst()) return null
            val request = it.getString(0)
            val wire = decrypt(db, it.getString(1), "pending:$namespace:$request")
            check(digest(envelope(wire).getString("requestId")) == request)
            return wire
        }
    }

    private fun marker(db: SQLiteDatabase, namespace: String, request: String): JSONObject? {
        db.query("closed", arrayOf("record"), "namespace=? AND request_digest=?", arrayOf(namespace, request), null, null, null).use {
            if (!it.moveToFirst()) return null
            val value = JSONObject(decrypt(db, it.getString(0), "closed:$namespace:$request"))
            check(value.length() == 5 && value.get("schema") is Int && value.getInt("schema") == 1 && value.getString("requestDigest") == request)
            check(value.getString("reason") in setOf("EXPIRED", "ERASED", "CHECKED"))
            check(value.get("knownSuccessful") is Boolean && value.getLong("acknowledgedAt") >= 0)
            return value
        }
    }

    private fun receipt(row: JSONObject): Map<String, Any> = mapOf(
        "schema" to row.getInt("schema"), "requestDigest" to row.getString("requestDigest"),
        "reason" to row.getString("reason"), "knownSuccessful" to row.getBoolean("knownSuccessful"),
        "acknowledgedAt" to row.getLong("acknowledgedAt"))

    private fun execute(method: String, args: Map<*, *>): Any? {
        val slot = args["slot"] as? String ?: error("slot")
        check(slot.startsWith("parent.pending.v1.") && slot.length <= 8192)
        val namespace = digest(slot)
        if (method == "digest") {
            val id = args["requestId"] as? String ?: error("request")
            check(id.isNotBlank() && id.length <= 128)
            return digest(id)
        }
        val db = helper.writableDatabase
        if (method == "list") {
            val rows = mutableListOf<String>()
            db.query("pending", arrayOf("namespace", "request_digest", "record"),
                "collection_digest=?", arrayOf(namespace), null, null, "namespace", "21").use {
                while (it.moveToNext()) {
                    val owner = it.getString(0); val request = it.getString(1)
                    val wire = decrypt(db, it.getString(2), "pending:$owner:$request")
                    check(digest(envelope(wire).getString("requestId")) == request)
                    rows.add(wire)
                }
            }
            check(rows.size <= 20)
            return rows
        }
        if (method == "read") return pending(db, namespace)
        db.beginTransaction()
        try {
            val old = pending(db, namespace)
            val value: Any = when (method) {
                "reserve" -> {
                    val wire = args["next"] as? String ?: error("next")
                    val next = envelope(wire)
                    val request = digest(next.getString("requestId"))
                    val collection = args["collection"] as? String
                    check(!args.containsKey("collection") || collection != null)
                    val group = collection?.let {
                        check(it.startsWith("parent.pending.v1.") && it.length <= 8192 && slot.startsWith("$it."))
                        digest(it)
                    }
                    if (old != null || marker(db, namespace, request) != null) false else {
                        if (group != null) db.rawQuery("SELECT COUNT(*) FROM pending WHERE collection_digest=?", arrayOf(group)).use {
                            check(it.moveToFirst() && it.getInt(0) < 20)
                        }
                        check(next.isNull("terminal") && !next.getBoolean("knownSuccessful"))
                        db.insertOrThrow("pending", null, ContentValues().apply {
                            put("namespace", namespace); put("request_digest", request)
                            put("collection_digest", group)
                            put("record", encrypt(db, wire, "pending:$namespace:$request"))
                        })
                        true
                    }
                }
                "replace" -> {
                    val expected = args["expected"] as? String ?: error("expected")
                    val wire = args["next"] as? String ?: error("next")
                    if (old != expected) false else {
                        val before = envelope(expected); val next = envelope(wire)
                        check(before.getString("requestId") == next.getString("requestId"))
                        check(before.getString("payload") == next.getString("payload"))
                        check(!before.getBoolean("knownSuccessful") || next.getBoolean("knownSuccessful"))
                        val terminal = before.optString("terminal")
                        check(terminal !in setOf("EXPIRED", "ERASED") ||
                            next.optString("terminal") == terminal || terminal == "EXPIRED" && next.optString("terminal") == "ERASED")
                        val request = digest(next.getString("requestId"))
                        check(db.update("pending", ContentValues().apply {
                            put("record", encrypt(db, wire, "pending:$namespace:$request"))
                        }, "namespace=?", arrayOf(namespace)) == 1)
                        true
                    }
                }
                "finish" -> {
                    val expected = args["expected"] as? String ?: error("expected")
                    val before = envelope(expected)
                    val terminal = args["terminal"] as? Boolean ?: error("terminal")
                    check(terminal == !before.isNull("terminal"))
                    val request = digest(before.getString("requestId"))
                    val previous = marker(db, namespace, request)
                    if (old == null && previous != null) {
                        check(previous.getString("reason") == if (terminal) before.getString("terminal") else "CHECKED")
                        check(previous.getBoolean("knownSuccessful") == before.getBoolean("knownSuccessful"))
                        receipt(previous)
                    } else {
                        check(old == expected && previous == null)
                        val closed = JSONObject().put("schema", 1).put("requestDigest", request)
                            .put("reason", if (terminal) before.getString("terminal") else "CHECKED")
                            .put("knownSuccessful", before.getBoolean("knownSuccessful"))
                            .put("acknowledgedAt", System.currentTimeMillis().coerceAtLeast(0))
                        db.insertOrThrow("closed", null, ContentValues().apply {
                            put("namespace", namespace); put("request_digest", request)
                            put("record", encrypt(db, closed.toString(), "closed:$namespace:$request"))
                        })
                        check(db.delete("pending", "namespace=?", arrayOf(namespace)) == 1)
                        receipt(marker(db, namespace, request) ?: error("receipt"))
                    }
                }
                else -> error("method")
            }
            db.setTransactionSuccessful()
            return value
        } finally { db.endTransaction() }
    }

    fun close() {
        if (!closing.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        executor.execute { helper.close() }
        executor.shutdown()
    }

    companion object {
        private const val keyAlias = "com.aimanager.parent.operation-journal.v1"
        private val keyLock = Any()
    }
}
