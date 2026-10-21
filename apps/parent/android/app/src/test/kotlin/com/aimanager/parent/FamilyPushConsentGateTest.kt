package com.aimanager.parent

import org.junit.Assert.*
import org.junit.Test

class FamilyPushConsentGateTest {
    @Test fun freshApplicationDoesNotInitializeSdkBeforeExplicitPersistedConsent() {
        var stored=false; var calls=0
        val gate=FamilyPushConsentGate(true,{stored},{stored=it;true},{calls++;true})
        assertFalse(gate.restore()); assertEquals(0,calls)
        assertTrue(gate.enableAfterConsent()); assertTrue(stored); assertEquals(1,calls)
        assertTrue(gate.restore()); assertEquals(1,calls)
        assertTrue(gate.revokeConsent()); assertFalse(stored)
        val next=FamilyPushConsentGate(true,{stored},{stored=it;true},{calls++;true})
        assertFalse(next.restore()); assertEquals(1,calls)
    }
    @Test fun uncertainConsentPersistenceOrDisabledBuildNeverCallsSdk() {
        var calls=0
        val failed=FamilyPushConsentGate(true,{false},{false},{calls++;true})
        assertFalse(failed.enableAfterConsent()); assertEquals(0,calls)
        val disabled=FamilyPushConsentGate(false,{true},{true},{calls++;true})
        assertFalse(disabled.restore()); assertFalse(disabled.enableAfterConsent()); assertEquals(0,calls)
    }
    @Test fun authorizedSdkInitializationFailureCanRecoverOnNextApplication() {
        var stored=false; var succeeds=false
        val gate=FamilyPushConsentGate(true,{stored},{stored=it;true},{succeeds})
        assertFalse(gate.enableAfterConsent()); assertTrue(stored)
        succeeds=true; assertTrue(gate.restore())
    }
    @Test fun lateSdkCallbacksCannotReopenAfterConsentRevocationOrNewRegistration() {
        var stored=false
        val gate=FamilyPushConsentGate(true,{stored},{stored=it;true},{true})
        assertTrue(gate.enableAfterConsent()); val old=gate.operationEpoch
        assertTrue(gate.isCurrent(old)); assertTrue(gate.revokeConsent()); assertFalse(gate.isCurrent(old))
        assertTrue(gate.enableAfterConsent()); assertFalse(gate.isCurrent(old)); assertTrue(gate.isCurrent(gate.operationEpoch))
    }
}
