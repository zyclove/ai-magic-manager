package com.aimanager.parent

/** Only opaque references cross the push boundary; every read uses OIDC again. */
object FamilyPushProtocol {
    private val idPattern=Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    fun validId(value: String?)=value!=null && idPattern.matches(value)
    data class Payload(val eventId:String,val deliveryId:String,val installationId:String,val deepLink:String)
    fun parse(value:Map<String,String>):Payload? {
        if(value.keys!=setOf("eventId","deliveryId","installationId","deepLink")) return null
        val event=value["eventId"]; val delivery=value["deliveryId"]; val installation=value["installationId"]
        if(!validId(event)||!validId(delivery)||!validId(installation)||value["deepLink"]!="aimanager://notifications/$event") return null
        return Payload(event!!,delivery!!,installation!!,value["deepLink"]!!)
    }
    class Guard {
        var installationId:String?=null; private set
        private val seen=LinkedHashSet<Pair<String,String>>()
        val seenCount get()=seen.size
        fun activate(id:String) { require(validId(id)); if(installationId!=id) seen.clear(); installationId=id }
        fun deactivate() { installationId=null; seen.clear() }
        fun restoreSeen(values:List<Pair<String,String>>) { for(value in values.takeLast(128)) if(validId(value.first)&&validId(value.second)) seen.add(value) }
        fun seenValues()=seen.toList()
        fun receive(value:Payload):Boolean {
            if(installationId!=value.installationId||!validId(value.eventId)||!validId(value.deliveryId)||seen.any { it.first==value.eventId||it.second==value.deliveryId }) return false
            seen.add(value.eventId to value.deliveryId); while(seen.size>128) seen.remove(seen.first()); return true
        }
    }
}
