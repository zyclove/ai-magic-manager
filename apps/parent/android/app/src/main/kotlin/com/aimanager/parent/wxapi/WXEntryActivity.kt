package com.aimanager.parent.wxapi

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.aimanager.parent.BuildConfig
import com.aimanager.parent.ConsumerWeChatAuthBridge
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler
import com.tencent.mm.opensdk.openapi.WXAPIFactory

class WXEntryActivity : Activity(), IWXAPIEventHandler {
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); handle(intent) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handle(intent) }
    private fun handle(intent: Intent) {
        if (BuildConfig.WECHAT_APP_ID.isBlank()) { finish(); return }
        val api = WXAPIFactory.createWXAPI(applicationContext, BuildConfig.WECHAT_APP_ID, true)
        try { if (!api.handleIntent(intent, this)) finish() } catch (_: Exception) { finish() } finally { api.detach() }
    }
    override fun onReq(request: BaseReq) { finish() }
    override fun onResp(response: BaseResp) {
        if (response is SendAuth.Resp) ConsumerWeChatAuthBridge.onResponse(response)
        finish()
    }
}
