package com.aimanager.parent

import org.junit.Assert.*
import org.junit.Test

class FamilyPushProtocolTest {
    private val event = "00000000-0000-4000-8000-000000000001"
    private val delivery = "00000000-0000-4000-8000-000000000002"
    private val installation = "00000000-0000-4000-8000-000000000003"
    private fun body() = mapOf("eventId" to event,"deliveryId" to delivery,"installationId" to installation,"deepLink" to "aimanager://notifications/$event")
    @Test fun rejectsHiddenAuthorityOrAlternateRoutes() {
        assertNotNull(FamilyPushProtocol.parse(body()))
        assertNull(FamilyPushProtocol.parse(body() + ("tenantId" to installation)))
        assertNull(FamilyPushProtocol.parse(body() + ("deepLink" to "aimanager://notifications/$event?child=secret")))
        assertNull(FamilyPushProtocol.parse(body() + ("eventId" to "ABCDEF00-0000-4000-8000-000000000001")))
        assertNull(FamilyPushProtocol.parse(body() + ("deepLink" to "aimanager://notifications/$delivery")))
    }
    @Test fun guardRejectsOldInstallationAndDeduplicatesEventAndDelivery() {
        val guard=FamilyPushProtocol.Guard()
        val value=FamilyPushProtocol.parse(body())!!
        assertFalse(guard.receive(value))
        guard.activate(installation)
        assertTrue(guard.receive(value)); assertFalse(guard.receive(value))
        assertFalse(guard.receive(value.copy(deliveryId="00000000-0000-4000-8000-000000000004")))
        guard.deactivate(); assertFalse(guard.receive(value))
        guard.activate("00000000-0000-4000-8000-000000000005")
        assertFalse(guard.receive(value))
    }
    @Test fun malformedIdentifiersAreRejectedAndDedupMemoryIsBounded() {
        assertNull(FamilyPushProtocol.parse(body() + ("eventId" to "1-1-1-1-1")))
        val guard=FamilyPushProtocol.Guard(); guard.activate(installation)
        for(i in 1..300) {
            val id=String.format("10000000-0000-4000-8000-%012d",i)
            assertTrue(guard.receive(FamilyPushProtocol.Payload(id,id,installation,"aimanager://notifications/$id")))
        }
        assertTrue(guard.seenCount <= 128)
    }
    @Test fun invitationSecretRemainsSeparateFromOpaquePushRoute() {
        val token="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
        val value=FamilyInvitationLinkProtocol.parse("aimanager://family-invitation?id=$event&token=$token")!!
        assertEquals(event,value.id); assertEquals(token,value.token)
        for(bad in listOf("aimanager://family-invitation?id=$event&token=$token&other=1","aimanager://family-invitation?id=$event&token=$token#x","aimanager://family-invitation?id=$event&token=short","aimanager://family-invitation?id=$event&id=$event&token=$token")) assertNull(FamilyInvitationLinkProtocol.parse(bad))
    }
}
