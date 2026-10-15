package com.aimanager.child

import android.content.Context
import android.content.res.Configuration
import android.app.UiModeManager
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.io.File
import java.util.concurrent.Executors

/** Platform glue only. Encryption/key management remain in the vetted plugin.
 * No device-owner, accessibility, VPN, app suspension or admin role is claimed. */
class MainActivity: FlutterActivity() {
    // Flutter can detach and reattach an engine to the same Activity. A closed
    // executor must never be reused for a later durability barrier.
    private var storageExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var observationHost: ObservationHost? = null
    private val deviceKeysHost = DeviceKeysHost()
    private var managedFeedbackHost: ManagedFeedbackHost? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        managedFeedbackHost?.close()
        managedFeedbackHost = ManagedFeedbackHost(this, engine.dartExecutor.binaryMessenger)
        if (storageExecutor.isShutdown) {
            storageExecutor = Executors.newSingleThreadExecutor()
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        observationHost = ObservationHost(this)
        AndroidObservationApi.setUp(engine.dartExecutor.binaryMessenger, observationHost)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.child/device_keys")
            .setMethodCallHandler { call, result ->
                storageExecutor.execute {
                    try {
                        val output = deviceKeysHost.invoke(call.method, call.arguments)
                        mainHandler.post { result.success(output) }
                    } catch (_: Exception) {
                        // Arguments, aliases, private material and provider errors
                        // must not be reflected into Flutter logs or UI text.
                        mainHandler.post { result.error("DEVICE_KEY_UNAVAILABLE", "Device key unavailable", null) }
                    }
                }
            }
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
                    "flushAgentFiles" -> storageExecutor.execute {
                        // Only persist metadata in this app's private files
                        // directory. The Dart caller cannot supply an external
                        // path or use this channel to remove arbitrary files.
                        val success = try {
                            val requested = call.argument<String>("directory")
                            val root = applicationContext.filesDir.canonicalFile
                            val target = requested?.let { File(it).canonicalFile }
                            if (target == null || !target.isDirectory ||
                                !(target == root || target.path.startsWith(root.path + File.separator))) {
                                false
                            } else {
                                val descriptor = Os.open(target.path,
                                    OsConstants.O_RDONLY, 0)
                                try { Os.fsync(descriptor); true }
                                finally { Os.close(descriptor) }
                            }
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
        managedFeedbackHost?.close()
        managedFeedbackHost = null
        AndroidObservationApi.setUp(engine.dartExecutor.binaryMessenger, null)
        observationHost?.close()
        observationHost = null
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.child/runtime").setMethodCallHandler(null)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.aimanager.child/device_keys").setMethodCallHandler(null)
        storageExecutor.shutdown()
        super.cleanUpFlutterEngine(engine)
    }
}
