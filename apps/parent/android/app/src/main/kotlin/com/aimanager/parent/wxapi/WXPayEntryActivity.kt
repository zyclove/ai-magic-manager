package com.aimanager.parent.wxapi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import com.aimanager.parent.BuildConfig
import com.aimanager.parent.FamilyPayBridge
import com.tencent.mm.opensdk.constants.ConstantsAPI
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler
import com.tencent.mm.opensdk.openapi.WXAPIFactory

/** Exported OpenSDK return point. Records a return signal, never a paid state. */
class WXPayEntryActivity : Activity(), IWXAPIEventHandler {
    override fun onCreate(state: Bundle?) { super.onCreate(state); accept(intent) }
    override fun onNewIntent(next: Intent) { super.onNewIntent(next); setIntent(next); accept(next) }
    private fun accept(incoming: Intent?) {
        val appId = BuildConfig.WECHAT_APP_ID
        if (incoming == null || !appId.matches(Regex("wx[0-9a-fA-F]{16}"))) { finish(); return }
        val api = WXAPIFactory.createWXAPI(this, appId, true)
        try { if (!api.handleIntent(incoming, this)) finish() }
        catch (_: Exception) { finish() }
        finally { api.detach() }
    }
    override fun onReq(request: BaseReq) { finish() }
    override fun onResp(response: BaseResp) {
        if (response.type == ConstantsAPI.COMMAND_PAY_BY_WX) {
            val prefs = applicationContext.getSharedPreferences(FamilyPayBridge.PREFERENCES, Context.MODE_PRIVATE)
            val pending = prefs.getString("attemptId", null)
            if (pending != null && response.transaction == pending) {
                val state = when (response.errCode) {
                    BaseResp.ErrCode.ERR_OK -> "RETURNED"
                    BaseResp.ErrCode.ERR_USER_CANCEL -> "CANCELLED"
                    else -> "SDK_ERROR"
                }
                prefs.edit().putString("returnState", state).commit()
            }
        }
        finish()
    }
}
