package com.aimanager.parent

import android.Manifest
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.alibaba.sdk.android.push.CloudPushService
import com.alibaba.sdk.android.push.CommonCallback
import com.alibaba.sdk.android.push.MessageReceiver
import com.alibaba.sdk.android.push.noonesdk.PushInitConfig
import com.alibaba.sdk.android.push.noonesdk.PushServiceFactory
import com.alibaba.sdk.android.push.notification.CPushMessage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class ParentApplication : Application() {
    private val pushConsent by lazy { FamilyPushConsentGate(BuildConfig.ALIYUN_PUSH_ENABLED,
        { getSharedPreferences("family_push_consent_v1",MODE_PRIVATE).getBoolean("consented",false) },
        { getSharedPreferences("family_push_consent_v1",MODE_PRIVATE).edit().putBoolean("consented",it).commit() },
        { initializePush() }) }
    override fun onCreate() {
        super.onCreate()
        // Existing explicit consent survives ordinary process restarts. Fresh
        // installations do not initialize this SDK or open its connection.
        FamilyPushRuntime.sdkConfigured=BuildConfig.ALIYUN_PUSH_ENABLED
        FamilyPushRuntime.sdkInitialized=pushConsent.restore()
    }
    private fun initializePush():Boolean = try {
            PushServiceFactory.getCloudPushService().setLogLevel(CloudPushService.LOG_OFF)
            PushServiceFactory.init(PushInitConfig.Builder().application(this)
                .appKey(BuildConfig.ALIYUN_PUSH_APP_KEY).appSecret(BuildConfig.ALIYUN_PUSH_APP_SECRET)
                .disableChannelProcess(true).loopStartChannel(false).build())
            true
        } catch (_: Exception) { false }
    fun initializeAfterExplicitConsent():Boolean {
        check(Looper.myLooper()==Looper.getMainLooper())
        FamilyPushRuntime.sdkInitialized=pushConsent.enableAfterConsent()
        return FamilyPushRuntime.sdkInitialized
    }
    fun revokePushConsent():Boolean=pushConsent.revokeConsent()
    fun pushOperationEpoch()=pushConsent.operationEpoch
    fun pushOperationCurrent(epoch:Long)=pushConsent.isCurrent(epoch)
}

/** Encrypted guard only: no actor, child name, provider token or login token. */
private class FamilyPushGuardStore(context:Context) {
    private val preferences=context.getSharedPreferences("family_push_guard_v1",Context.MODE_PRIVATE)
    private fun key():SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
        (store.getKey("family_push_guard_v1",null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").also {
            it.init(KeyGenParameterSpec.Builder("family_push_guard_v1",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    fun read():JSONObject? {
        val encoded=preferences.getString("sealed",null)?:return null
        if(encoded.length>24000) return null
        val bytes=Base64.decode(encoded,Base64.NO_WRAP); if(bytes.size<29) return null
        val cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,bytes.copyOfRange(0,12)))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12,bytes.size)),Charsets.UTF_8))
    }
    fun write(value:JSONObject):Boolean {
        val cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key())
        val bytes=cipher.iv+cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        return preferences.edit().putString("sealed",Base64.encodeToString(bytes,Base64.NO_WRAP)).commit()
    }
    fun clear()=preferences.edit().remove("sealed").commit()
}

object FamilyPushRuntime {
    const val channelId="family_updates"
    var sdkConfigured=false
    var sdkInitialized=false
    private var pendingClick:FamilyPushProtocol.Payload?=null
    private fun manager(context:Context)=context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    fun ensureChannel(context:Context) { if(Build.VERSION.SDK_INT>=26) manager(context).createNotificationChannel(NotificationChannel(channelId,"家庭提醒",NotificationManager.IMPORTANCE_DEFAULT).also { it.description="申请、设备状态及家庭约定提醒"; it.lockscreenVisibility=android.app.Notification.VISIBILITY_PRIVATE }) }
    fun permission(context:Context)=NotificationManagerCompat.from(context).areNotificationsEnabled() && (Build.VERSION.SDK_INT<33||context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED)
    fun channelEnabled(context:Context)=Build.VERSION.SDK_INT<26 || manager(context).getNotificationChannel(channelId)?.importance?.let { it!=NotificationManager.IMPORTANCE_NONE } == true
    fun state(context:Context)=mapOf("configured" to sdkConfigured,"permissionGranted" to permission(context),"channelEnabled" to channelEnabled(context))
    @Synchronized fun activate(context:Context,id:String):Boolean {
        if(!sdkInitialized||!FamilyPushProtocol.validId(id)||!permission(context)||!channelEnabled(context)) return false
        return try { val store=FamilyPushGuardStore(context); val old=store.read(); val seen=if(old?.optString("installationId")==id) old.optJSONArray("seen")?:JSONArray() else JSONArray(); store.write(JSONObject().put("installationId",id).put("enabled",true).put("seen",seen)) } catch(_:Exception) { false }
    }
    @Synchronized fun deactivate(context:Context,preserveClick:Boolean=false):Boolean {
        if(!preserveClick) pendingClick=null
        // Only our tag is cancelled; unrelated order/account notifications stay.
        if(Build.VERSION.SDK_INT>=23) manager(context).activeNotifications.filter { it.tag=="family_updates" }.forEach { manager(context).cancel(it.tag,it.id) }
        return try { val store=FamilyPushGuardStore(context); if(preserveClick) { val old=store.read(); if(old==null) true else store.write(old.put("enabled",false)) } else {
            val stopped=store.clear()
            val consentStopped=(context.applicationContext as? ParentApplication)?.revokePushConsent()?:false
            stopped&&consentStopped
        } } catch(_:Exception) { false }
    }
    @Synchronized fun receive(context:Context,raw:String) {
        if(!sdkInitialized||raw.toByteArray(Charsets.UTF_8).size>1024||!permission(context)||!channelEnabled(context)) return
        try {
            val json=JSONObject(raw); val values=mutableMapOf<String,String>()
            for(key in json.keys()) { val value=json.get(key); if(value !is String) return; values[key]=value }
            val payload=FamilyPushProtocol.parse(values)?:return
            val store=FamilyPushGuardStore(context); val saved=store.read()?:return
            if(!saved.optBoolean("enabled",false)||saved.optString("installationId")!=payload.installationId) return
            val guard=FamilyPushProtocol.Guard(); guard.activate(payload.installationId)
            val seen=saved.optJSONArray("seen")?:JSONArray(); val restored=mutableListOf<Pair<String,String>>()
            for(i in 0 until minOf(seen.length(),128)) { val entry=seen.optJSONArray(i)?:continue; restored.add(entry.optString(0) to entry.optString(1)) }
            guard.restoreSeen(restored); if(!guard.receive(payload)) return
            val updated=JSONArray(); guard.seenValues().forEach { updated.put(JSONArray().put(it.first).put(it.second)) }
            // A duplicate arriving during a crash cannot be displayed twice.
            if(!store.write(saved.put("seen",updated))) return
            val intent=Intent(context,MainActivity::class.java).setAction("com.aimanager.parent.FAMILY_UPDATE")
                .setData(Uri.parse(payload.deepLink)).putExtra("family_push_installation",payload.installationId)
                .putExtra("family_push_delivery",payload.deliveryId).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val pending=PendingIntent.getActivity(context,payload.deliveryId.hashCode(),intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification=NotificationCompat.Builder(context,channelId).setSmallIcon(com.aimanager.parent.R.drawable.ic_manager)
                .setContentTitle("家庭提醒").setContentText("家庭中有待查看的更新，请打开应用查看。")
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(pending).build()
            manager(context).notify("family_updates",payload.deliveryId.hashCode(),notification)
        } catch(_:Exception) { /* Malformed or unavailable storage: no display, no sensitive logging. */ }
    }
    @Synchronized fun capture(intent:Intent?) {
        val link=intent?.dataString?:return
        if(!link.startsWith("aimanager://notifications/")) return
        val event=link.removePrefix("aimanager://notifications/")
        pendingClick=FamilyPushProtocol.parse(mapOf("eventId" to event,"deliveryId" to (intent.getStringExtra("family_push_delivery")?:""),"installationId" to (intent.getStringExtra("family_push_installation")?:""),"deepLink" to link))
        intent.data=null; intent.removeExtra("family_push_installation"); intent.removeExtra("family_push_delivery")
    }
    @Synchronized fun takeClick(context:Context):Map<String,String>? {
        val value=pendingClick; pendingClick=null; if(value==null) return null
        return try { val saved=FamilyPushGuardStore(context).read(); if(saved?.optBoolean("enabled")!=true||saved.optString("installationId")!=value.installationId) null else mapOf("deepLink" to value.deepLink,"installationId" to value.installationId) } catch(_:Exception) { null }
    }
}

/** SDK NOTICE is always suppressed. Only guarded MESSAGE can show locally. */
class FamilyAliyunMessageReceiver:MessageReceiver() {
    override fun showNotificationNow(context:Context?,map:MutableMap<String,String>?)=false
    override fun onMessage(context:Context?,message:CPushMessage?) { if(context!=null&&message?.content!=null) FamilyPushRuntime.receive(context,message.content) }
    override fun onNotification(context:Context?,title:String?,summary:String?,extra:MutableMap<String,String>?) {}
    override fun onNotificationOpened(context:Context?,title:String?,summary:String?,extra:String?) {}
    override fun onNotificationClickedWithNoAction(context:Context?,title:String?,summary:String?,extra:String?) {}
    override fun onNotificationRemoved(context:Context?,messageId:String?) {}
    override fun onNotificationReceivedInApp(context:Context?,title:String?,summary:String?,extra:MutableMap<String,String>?,openType:Int,openActivity:String?,openUrl:String?) {}
}

class FamilyPushHost(private val activity:FlutterActivity,messenger:BinaryMessenger) {
    companion object { const val permissionRequest=42017 }
    private val handler=Handler(Looper.getMainLooper())
    private var permissionResult:MethodChannel.Result?=null
    private var closed=false
    private val channel=MethodChannel(messenger,"com.aimanager.parent/family-push")
    init { channel.setMethodCallHandler { call,result ->
        when(call.method) {
            "state" -> result.success(FamilyPushRuntime.state(activity))
            "requestPermission" -> {
                if(!FamilyPushRuntime.sdkConfigured) result.success(FamilyPushRuntime.state(activity))
                else if(permissionResult!=null) result.error("PUSH_BUSY","请完成当前授权",null)
                else { FamilyPushRuntime.ensureChannel(activity); if(Build.VERSION.SDK_INT>=33&&!FamilyPushRuntime.permission(activity)) { permissionResult=result; activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),permissionRequest) } else result.success(FamilyPushRuntime.state(activity)) }
            }
            "register" -> register(result)
            "activate" -> { val id=call.argument<String>("installationId"); result.success(id!=null&&FamilyPushRuntime.activate(activity,id)) }
            "deactivate" -> { val preserve=call.argument<Boolean>("preserveClick")==true; if(!preserve) { permissionResult?.error("PUSH_CANCELLED","授权已结束",null); permissionResult=null }; val success=FamilyPushRuntime.deactivate(activity,preserve); if(!preserve&&FamilyPushRuntime.sdkInitialized) try { PushServiceFactory.getCloudPushService().turnOffPushChannel(ignoredCallback()) } catch(_:Exception) {}; result.success(success) }
            "takeClick" -> result.success(FamilyPushRuntime.takeClick(activity))
            else -> result.notImplemented()
        }
    } }
    private fun ignoredCallback()=object:CommonCallback { override fun onSuccess(value:String?) {} ; override fun onFailed(code:String?,message:String?) {} }
    private fun register(result:MethodChannel.Result) {
        if(!FamilyPushRuntime.sdkConfigured||!FamilyPushRuntime.permission(activity)||!FamilyPushRuntime.channelEnabled(activity)) { result.error("PUSH_NOT_READY","请先开启此设备的通知权限",null); return }
        val application=activity.application as? ParentApplication
        if(application?.initializeAfterExplicitConsent()!=true) { result.error("PUSH_UNAVAILABLE","通知初始化暂不可用，请稍后重试",null); return }
        val epoch=application.pushOperationEpoch()
        var finished=false
        fun finish(token:String?) { handler.post { if(!finished) { finished=true; if(closed||!application.pushOperationCurrent(epoch)||token==null||token.length !in 8..512||!Regex("^[A-Za-z0-9_.:-]+$").matches(token)) result.error("PUSH_UNAVAILABLE","通知注册暂不可用，请稍后重试",null) else result.success(token) } } }
        handler.postDelayed({ finish(null) },20000)
        try { val service=PushServiceFactory.getCloudPushService(); service.register(activity.applicationContext,object:CommonCallback {
            override fun onSuccess(value:String?) { handler.post { if(finished||closed||!application.pushOperationCurrent(epoch)) finish(null) else service.turnOnPushChannel(object:CommonCallback { override fun onSuccess(value:String?) { finish(service.deviceId) }; override fun onFailed(code:String?,message:String?) { finish(null) } }) } }
            override fun onFailed(code:String?,message:String?) { finish(null) }
        }) } catch(_:Exception) { finish(null) }
    }
    fun permissionResult(requestCode:Int):Boolean { if(requestCode!=permissionRequest) return false; permissionResult?.success(FamilyPushRuntime.state(activity)); permissionResult=null; return true }
    fun close() { closed=true; permissionResult?.error("PUSH_CANCELLED","授权已结束",null); permissionResult=null; channel.setMethodCallHandler(null) }
}
