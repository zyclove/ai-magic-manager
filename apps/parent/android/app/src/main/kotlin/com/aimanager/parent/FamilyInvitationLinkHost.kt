package com.aimanager.parent

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Secret ingress stays in RAM until the explicit acceptance flow encrypts it. */
object FamilyInvitationLinkHost {
    private var pending:FamilyInvitationLinkProtocol.Invitation?=null
    @Synchronized fun capture(intent:Intent?) {
        val raw=intent?.dataString ?: return
        if(raw.startsWith("aimanager://family-invitation")) { pending=FamilyInvitationLinkProtocol.parse(raw); intent.data=null }
    }
    fun install(messenger:BinaryMessenger):MethodChannel=MethodChannel(messenger,"com.aimanager.parent/links").also { channel ->
        channel.setMethodCallHandler { call,result ->
            if(call.method!="takeFamilyInvitation") result.notImplemented()
            else { val value=take(); result.success(value?.let { mapOf("id" to it.id,"token" to it.token) }) }
        }
    }
    @Synchronized private fun take():FamilyInvitationLinkProtocol.Invitation? { val result=pending; pending=null; return result }
}
