package com.aimanager.child.assisted

/** Feedback interruption is independent of the service binding lifetime. */
class AssistedServiceLifecycle(private val start: () -> Unit, private val stop: () -> Unit) {
    var connected = false; private set
    fun bind() { if(!connected) { connected = true; start() } }
    fun interruptFeedback() { /* The binding and background work remain active. */ }
    fun unbind() { if(connected) { connected = false; stop() } }
}
