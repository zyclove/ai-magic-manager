package com.aimanager.child

import android.content.Context
import android.content.res.Configuration
import android.app.UiModeManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** Platform glue only. Encryption/key management remain in the vetted plugin.
 * No device-owner, accessibility, VPN, app suspension or admin role is claimed. */
class MainActivity: FlutterActivity() {
    private val storageExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var observationHost: ObservationHost? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        observationHost = ObservationHost(this)
        AndroidObservationApi.setUp(engine.dartExecutor.binaryMessenger, observationHost)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.child/runtime")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "flushIdentity" -> storageExecutor.execute {
                        // v10.0.0 uses apply() for wrapping keys and the record.
                        // commit waits for previous apply writes, then persists a
                        // fresh marker. Keys/config must be durable before data.
                        val success = try {
                            listOf("FlutterSecureKeyStorage", "FlutterSecureStorageConfiguration", "aimanager_identity_v1")
                                .all { name -> applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
                                    .edit().putString("__durability_barrier", UUID.randomUUID().toString()).commit() }
                        } catch (_: Exception) { false }
                        mainHandler.post { result.success(success) }
                    }
                    "platformFacts" -> result.success(mapOf("osVersion" to "Android ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT}",
                        "isTelevision" to (getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION),
                        "systemEnforced" to false, "timeSource" to "OS_WALL_CLOCK"))
                    else -> result.notImplemented()
                }
            }
    }
    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        AndroidObservationApi.setUp(engine.dartExecutor.binaryMessenger, null)
        observationHost?.close()
        observationHost = null
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.child/runtime").setMethodCallHandler(null)
        storageExecutor.shutdown()
        super.cleanUpFlutterEngine(engine)
    }
}
