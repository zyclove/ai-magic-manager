package com.aimanager.child.assisted

import org.junit.Assert.*
import org.junit.Test

class AssistedServiceLifecycleTest {
    @Test fun feedbackInterruptionDoesNotRequireRebindingToKeepSyncAlive() {
        var starts = 0
        var stops = 0
        val lifetime = AssistedServiceLifecycle({ starts++ }, { stops++ })
        lifetime.bind()
        lifetime.interruptFeedback()
        assertTrue(lifetime.connected)
        assertEquals(1, starts)
        assertEquals(0, stops)
        lifetime.unbind()
        assertFalse(lifetime.connected)
        assertEquals(1, stops)
        lifetime.unbind()
        assertEquals(1, stops)
        lifetime.bind()
        assertTrue(lifetime.connected)
        assertEquals(2, starts)
    }
}
