package com.aimanager.parent

import android.app.Activity
import android.content.Context
import com.tencent.mm.opensdk.constants.Build
import com.tencent.mm.opensdk.modelpay.PayReq
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Dispatch only. A WeChat callback can never grant local subscription rights. */
object FamilyPayBridge {
    const val PREFERENCES = "family_wechat_pay_return"
    fun install(activity: Activity, messenger: BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, "com.aimanager.parent/wechat_pay")
        channel.setMethodCallHandler { call, result ->
            val prefs = activity.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            when (call.method) {
                "launch" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val attempt = arguments?.get("attemptId") as? String
                    val raw = arguments?.get("parameters") as? Map<*, *>
                    if (attempt.isNullOrBlank() || attempt.length > 100 || raw == null) {
                        result.error("INVALID_PAYMENT_PARAMETERS", "Payment parameters rejected", null)
                    } else {
                        try {
                            val p = FamilyPayParameters.from(raw, BuildConfig.WECHAT_APP_ID)
                            val api = WXAPIFactory.createWXAPI(activity.applicationContext, p.appId, true)
                            try {
                                if (!api.registerApp(p.appId)) {
                                    result.error("WECHAT_PAY_REGISTRATION_FAILED", "WeChat registration failed", null)
                                } else if (!api.isWXAppInstalled) {
                                    result.error("WECHAT_NOT_INSTALLED", "WeChat is not installed", null)
                                } else if (api.wxAppSupportAPI < Build.PAY_SUPPORTED_SDK_INT) {
                                    result.error("WECHAT_PAY_VERSION_UNSUPPORTED", "WeChat version does not support payment", null)
                                } else if (!prefs.edit().putString("attemptId", attempt).putString("appId", p.appId)
                                        .putString("returnState", "WAITING").commit()) {
                                    result.error("PAYMENT_RECOVERY_UNAVAILABLE", "Cannot persist payment reference", null)
                                } else {
                                    val request = PayReq().apply {
                                        appId = p.appId; partnerId = p.partnerId; prepayId = p.prepayId
                                        packageValue = p.packageValue; nonceStr = p.nonceStr
                                        timeStamp = p.timeStamp; sign = p.sign; transaction = attempt
                                    }
                                    if (api.sendReq(request)) result.success(mapOf("status" to "DISPATCHED"))
                                    else result.error("WECHAT_PAY_DISPATCH_FAILED", "WeChat did not accept the request", null)
                                }
                            } finally { api.detach() }
                        } catch (failure: IllegalArgumentException) {
                            result.error(failure.message ?: "INVALID_PAYMENT_PARAMETERS", "Payment parameters rejected", null)
                        } catch (_: Exception) {
                            result.error("WECHAT_PAY_DISPATCH_FAILED", "WeChat dispatch failed", null)
                        }
                    }
                }
                "status" -> {
                    val attempt = call.argument<String>("attemptId")
                    result.success(if (attempt != null && attempt == prefs.getString("attemptId", null))
                        mapOf("status" to prefs.getString("returnState", "WAITING")) else mapOf("status" to "UNKNOWN"))
                }
                "clear" -> {
                    val attempt = call.argument<String>("attemptId")
                    result.success(attempt != null && attempt == prefs.getString("attemptId", null) && prefs.edit().clear().commit())
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }
}
