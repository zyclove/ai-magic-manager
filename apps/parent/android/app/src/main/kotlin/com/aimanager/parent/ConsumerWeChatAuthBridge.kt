package com.aimanager.parent

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Native authorization codes are short lived, single use, and stay in memory. */
object ConsumerWeChatAuthBridge {
    private val state = ConsumerAuthState()
    private val handler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private val timeout = Runnable { finishError("WECHAT_AUTH_TIMEOUT", "微信授权已超时，请重试") }

    fun install(activity: Activity, messenger: BinaryMessenger): MethodChannel {
        return MethodChannel(messenger, "com.aimanager.parent/auth").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "wechatLogin") {
                    result.notImplemented()
                } else if (pending != null) {
                    result.error("WECHAT_AUTH_BUSY", "微信授权正在进行", null)
                } else if (!BuildConfig.WECHAT_APP_ID.matches(Regex("wx[0-9a-fA-F]{16}"))) {
                    result.error("WECHAT_AUTH_UNCONFIGURED", "微信登录暂未开放", null)
                } else {
                    val api = WXAPIFactory.createWXAPI(activity.applicationContext, BuildConfig.WECHAT_APP_ID, true)
                    try {
                        if (!api.registerApp(BuildConfig.WECHAT_APP_ID)) {
                            result.error("WECHAT_AUTH_REGISTRATION_FAILED", "微信应用注册失败", null)
                        } else if (!api.isWXAppInstalled) {
                            result.error("WECHAT_NOT_INSTALLED", "请先安装微信", null)
                        } else {
                            pending = result
                            val nonce = state.begin(SystemClock.elapsedRealtime())
                            val request = SendAuth.Req().apply {
                                scope = "snsapi_userinfo"
                                state = nonce
                                transaction = nonce
                            }
                            handler.postDelayed(timeout, 120000)
                            if (!api.sendReq(request)) finishError("WECHAT_AUTH_DISPATCH_FAILED", "未能打开微信授权")
                        }
                    } catch (_: Exception) {
                        if (pending === result) finishError("WECHAT_AUTH_DISPATCH_FAILED", "微信授权暂不可用")
                        else result.error("WECHAT_AUTH_DISPATCH_FAILED", "微信授权暂不可用", null)
                    } finally { api.detach() }
                }
            }
        }
    }

    fun onResponse(response: SendAuth.Resp) {
        if (pending == null || !state.accept(response.state, SystemClock.elapsedRealtime())) return
        val result = pending
        pending = null
        handler.removeCallbacks(timeout)
        val code = response.code
        when {
            response.errCode == BaseResp.ErrCode.ERR_USER_CANCEL -> result?.error("WECHAT_AUTH_CANCELLED", "已取消微信授权", null)
            response.errCode != BaseResp.ErrCode.ERR_OK -> result?.error("WECHAT_AUTH_REJECTED", "微信授权未完成", null)
            code == null || !code.matches(Regex("[A-Za-z0-9_-]{1,512}")) -> result?.error("WECHAT_AUTH_INVALID_CODE", "微信返回无效授权", null)
            else -> result?.success(code)
        }
    }

    private fun finishError(code: String, message: String) {
        state.cancel()
        handler.removeCallbacks(timeout)
        val result = pending
        pending = null
        result?.error(code, message, null)
    }

    fun cancelPending() { finishError("WECHAT_AUTH_CANCELLED", "授权已结束，请重新登录") }
}
