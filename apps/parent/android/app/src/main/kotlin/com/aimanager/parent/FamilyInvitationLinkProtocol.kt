package com.aimanager.parent

object FamilyInvitationLinkProtocol {
    data class Invitation(val id:String,val token:String)
    fun parse(raw:String):Invitation? {
        if(raw.length>180||!raw.startsWith("aimanager://family-invitation?")) return null
        val pairs=raw.removePrefix("aimanager://family-invitation?").split('&')
        if(pairs.size!=2) return null
        val values=mutableMapOf<String,String>()
        for(pair in pairs) { val parts=pair.split('='); if(parts.size!=2||values.put(parts[0],parts[1])!=null) return null }
        if(values.keys!=setOf("id","token")||!FamilyPushProtocol.validId(values["id"])||!Regex("^[A-Za-z0-9_-]{43}$").matches(values["token"]?:"")) return null
        return Invitation(values["id"]!!,values["token"]!!)
    }
}
