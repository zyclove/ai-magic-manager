package com.aimanager.parent

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** Small durability bridge for flutter_secure_storage 10.0.0 apply() writes. */
class MainActivity: FlutterActivity() {
    private var storageExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        if (storageExecutor.isShutdown) storageExecutor = Executors.newSingleThreadExecutor()
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.parent/storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "flushSecureStorage") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                storageExecutor.execute {
                    // A commit after the plugin's apply() waits for earlier queued
                    // writes. Persist key/config before the encrypted data record.
                    val success = try {
                        listOf("FlutterSecureKeyStorage", "FlutterSecureStorageConfiguration", "FlutterSecureStorage")
                            .all { name -> applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
                                .edit().putString("__durability_barrier", UUID.randomUUID().toString()).commit() }
                    } catch (_: Exception) { false }
                    mainHandler.post { result.success(success) }
                }
            }
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.parent/storage")
            .setMethodCallHandler(null)
        storageExecutor.shutdown()
        super.cleanUpFlutterEngine(engine)
    }
}
