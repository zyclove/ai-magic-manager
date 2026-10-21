package com.aimanager.parent

/** Separates application configuration from the adult's durable SDK consent. */
class FamilyPushConsentGate(
    private val configured:Boolean,
    private val read:()->Boolean,
    private val write:(Boolean)->Boolean,
    private val initialize:()->Boolean
) {
    private var initialized=false
    var operationEpoch=0L; private set
    fun restore():Boolean {
        if(!configured||!read()) return false
        if(!initialized) initialized=initialize()
        return initialized
    }
    fun enableAfterConsent():Boolean {
        if(!configured||!write(true)) return false
        operationEpoch++
        return restore()
    }
    fun isCurrent(epoch:Long)=epoch==operationEpoch&&initialized&&configured&&read()
    fun revokeConsent():Boolean { operationEpoch++; return write(false) }
}
