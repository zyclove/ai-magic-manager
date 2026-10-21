package com.aimanager.child.assisted

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import com.nimbusds.jose.util.JSONObjectUtils
import com.aimanager.child.BuildConfig

/** Only package/window changes are inspected. No nodes, text, inputs or chats. */
class FamilyAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var foregroundPackage: String? = null
    private var background: AndroidBackgroundSync? = null
    private val lifetime = AssistedServiceLifecycle({
        connected = true
        handler.removeCallbacks(ticker)
        handler.post(ticker)
        background = (background ?: AndroidBackgroundSync(applicationContext)).also { it.start() }
    }, {
        connected = false
        foregroundPackage = null
        handler.removeCallbacks(ticker)
        background?.stop()
    })
    private val ticker = object : Runnable {
        override fun run() {
            evaluate()
            handler.postDelayed(this, 5000L)
        }
    }
    override fun onServiceConnected() {
        foregroundPackage = null
        lifetime.bind()
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        // Never touch event.text, contentDescription, source, window nodes, or input values.
        foregroundPackage = event.packageName?.toString()?.takeIf { it.length <= 255 }
        evaluate()
    }
    private fun evaluate() {
        val host = AssistedRuntimeHost.get(this)
        AndroidIdentityGate.get(this).cached { lease ->
            val scope = try {
                val state = JSONObjectUtils.parse(lease.raw)
                require(state["apiRoot"] == BuildConfig.CHILD_API_ROOT.removeSuffix("/") &&
                    state["authenticationBlocked"] != true && state["phase"] in
                    setOf("active", "rotationRequested", "rotationPending", "activationUncertain"))
                AssistedScope(state["tenantId"] as String, state["deviceId"] as String, state["registrationId"] as String)
            } catch (_: Exception) { null }
            val result = host.observe(foregroundPackage, scope)
            if (result.status == AssistedStatus.ACTIVE && result.decision == AssistedDecision.RESTRICT &&
                foregroundPackage !in host.safePackages()) {
                // Reversible application-level help. Android can stop this service.
                host.actionResult(performGlobalAction(GLOBAL_ACTION_HOME))
            }
        }
    }
    override fun onInterrupt() {
        foregroundPackage = null
        lifetime.interruptFeedback()
    }
    override fun onUnbind(intent: Intent?): Boolean {
        lifetime.unbind()
        return super.onUnbind(intent)
    }
    override fun onDestroy() {
        lifetime.unbind()
        super.onDestroy()
    }
    companion object { @Volatile var connected: Boolean = false; private set }
}
