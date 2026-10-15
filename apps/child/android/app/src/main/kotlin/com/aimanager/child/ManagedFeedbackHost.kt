package com.aimanager.child

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.enterprise.feedback.KeyedAppState
import androidx.enterprise.feedback.KeyedAppStatesCallback
import androidx.enterprise.feedback.KeyedAppStatesReporter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** AndroidX callback success is local submission, including zero receivers; never cloud verification. */
internal class ManagedFeedbackHost(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "com.aimanager.child/managed_feedback")
    private val pending = mutableSetOf<Pending>()
    private var closed = false
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pause" -> { invalidate(); result.success(null) }
                "submit" -> {
                    var owned: Pending? = null
                    try {
                        require(!closed && pending.isEmpty())
                        val args = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
                        require(args.keys == setOf("proof"))
                        val proof = args["proof"] as? String ?: throw IllegalArgumentException()
                        val expires = ManagedFeedbackProof.expiresAt(proof, System.currentTimeMillis())
                        val state = KeyedAppState.builder().setKey("ai_manager.binding.v1")
                            .setSeverity(KeyedAppState.SEVERITY_INFO)
                            .setMessage("Identity feedback submitted; awaiting server verification")
                            .setData(proof).build()
                        val request = Pending(result)
                        owned = request
                        pending.add(request)
                        handler.postDelayed(request.timeout, minOf(10000, expires - System.currentTimeMillis()).coerceAtLeast(1))
                        reporter(app).setStatesImmediate(listOf(state)) { status, _ ->
                            handler.post {
                                request.finish(if (status == KeyedAppStatesCallback.STATUS_SUCCESS && System.currentTimeMillis() < expires) "SUBMITTED" else null)
                            }
                        }
                    } catch (_: Exception) {
                        // Do not surface SDK exceptions, JWTs, or provider details.
                        if (owned == null) result.error("MANAGED_FEEDBACK_UNAVAILABLE", "Feedback unavailable", null)
                        else owned.finish(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private inner class Pending(private val result: MethodChannel.Result) {
        private var done = false
        val timeout = Runnable { finish(null) }
        fun finish(status: String?) {
            if (done) return
            done = true
            handler.removeCallbacks(timeout)
            pending.remove(this)
            if (status != null && !closed) result.success(mapOf("status" to status))
            else result.error("MANAGED_FEEDBACK_UNAVAILABLE", "Feedback unavailable", null)
        }
    }
    private fun invalidate() { pending.toList().forEach { it.finish(null) } }
    fun close() {
        if (closed) return
        closed = true
        invalidate()
        channel.setMethodCallHandler(null)
    }
    companion object {
        @Volatile private var sharedReporter: KeyedAppStatesReporter? = null
        private fun reporter(context: Context): KeyedAppStatesReporter = sharedReporter ?: synchronized(this) {
            sharedReporter ?: KeyedAppStatesReporter.create(context).also { sharedReporter = it }
        }
    }
}
