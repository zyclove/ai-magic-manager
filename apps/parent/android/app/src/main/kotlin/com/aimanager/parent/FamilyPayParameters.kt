package com.aimanager.parent

/** Only the signed shape returned by the server may be dispatched to OpenSDK. */
data class FamilyPayParameters(
    val appId: String, val partnerId: String, val prepayId: String,
    val packageValue: String, val nonceStr: String, val timeStamp: String, val sign: String
) {
    companion object {
        fun from(value: Map<*, *>, configuredAppId: String): FamilyPayParameters {
            fun field(name: String): String = (value[name] as? String)?.takeIf { it.isNotEmpty() }
                ?: throw IllegalArgumentException("INVALID_PAYMENT_PARAMETERS")
            require(configuredAppId.matches(Regex("wx[0-9a-fA-F]{16}"))) { "WECHAT_PAY_NOT_CONFIGURED" }
            val result = FamilyPayParameters(field("appId"), field("partnerId"), field("prepayId"),
                field("packageValue"), field("nonceStr"), field("timeStamp"), field("sign"))
            require(result.appId == configuredAppId && result.partnerId.matches(Regex("[0-9]{5,20}")) &&
                result.prepayId.matches(Regex("[A-Za-z0-9_-]{1,128}")) && result.packageValue == "Sign=WXPay" &&
                result.nonceStr.matches(Regex("[A-Za-z0-9]{1,32}")) && result.timeStamp.matches(Regex("[0-9]{10}")) &&
                result.sign.matches(Regex("[A-Za-z0-9+/=]{1,2048}"))) { "INVALID_PAYMENT_PARAMETERS" }
            return result
        }
    }
}
