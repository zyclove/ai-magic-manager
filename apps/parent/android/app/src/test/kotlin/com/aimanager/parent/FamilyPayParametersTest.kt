package com.aimanager.parent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FamilyPayParametersTest {
    private val appId = "wx0123456789abcdef"
    private fun parameters() = mapOf(
        "appId" to appId, "partnerId" to "1234567890", "prepayId" to "wxprepay123",
        "packageValue" to "Sign=WXPay", "nonceStr" to "abcdefghijklmnop",
        "timeStamp" to "1792051200", "sign" to "c2lnbmF0dXJl"
    )

    @Test fun `accepts signed provider shape for the configured app only`() {
        val result = FamilyPayParameters.from(parameters(), appId)
        assertEquals("Sign=WXPay", result.packageValue)
        assertEquals("wxprepay123", result.prepayId)
        assertThrows(IllegalArgumentException::class.java) {
            FamilyPayParameters.from(parameters(), "wx1111111111111111")
        }
    }
    @Test fun `rejects substituted package field or empty app configuration`() {
        assertThrows(IllegalArgumentException::class.java) {
            FamilyPayParameters.from(parameters() + ("packageValue" to "intent://evil"), appId)
        }
        assertThrows(IllegalArgumentException::class.java) { FamilyPayParameters.from(parameters(), "") }
    }
}
