package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderContracts.*;
import com.aimanager.commerce.FamilySalesGate;
import java.util.List;
import org.springframework.stereotype.Service;

/** 真实证据采集及显式启售机制尚未交付，任何配置组合都不能自行开放收费。 */
@Service
final class ProviderFamilySalesGate implements FamilySalesGate {
  @Override public boolean allowed(){return false;}
  static SalesGateView view(boolean requested){return new SalesGateView(false,"CLOSED",List.of(
      blocked("IDENTITY_PROVIDER_ACCEPTANCE","短信与微信真实验收","完成十二项真实账号联调，并由可信服务端事实核对结果。"),
      blocked("SIGNED_ANDROID_ACCEPTANCE","安卓真机验收","使用正式签名安装包，完成支持机型与连续运行验收。"),
      blocked("WECHAT_PAYMENT_ACCEPTANCE","付款与售后验收","完成真实付款、退款、自动关单及日账单对账。"),
      blocked("RELEASE_ADMISSION","发布条件","核对国内网络、正式发布材料和渠道准入。"),
      new Check("SALES_CONFIGURATION","开售配置","收费开放",requested?"READY":"BLOCKED",requested?"SALES_REQUESTED":"SALES_NOT_REQUESTED",
          requested?"已登记开售意图；真实验收完成前仍保持关闭。":"真实验收完成后，再单独准备受控启售。")));}
  private static Check blocked(String id,String label,String action){return new Check(id,label,"收费开放","BLOCKED","REAL_ACCEPTANCE_REQUIRED",action);}
}
