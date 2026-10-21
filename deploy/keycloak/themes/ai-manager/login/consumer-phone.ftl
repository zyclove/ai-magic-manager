<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
  <#if section == "header">
    <#if accountAction??>
      <#if accountAction == "CHANGE_PHONE"><#if (accountStep!'') == "NEW">验证新手机号<#else>验证当前手机号</#if>
      <#elseif accountAction == "RECOVER_PHONE">找回原账号
      <#elseif accountAction == "BIND_WECHAT">绑定微信
      <#elseif accountAction == "UNBIND_WECHAT">解绑微信
      <#else>账号安全</#if>
    <#elseif wechatBinding!false>验证手机号，完成微信绑定<#else>手机号登录</#if>
  <#elseif section == "form">
    <#if accountAction??>
      <#if accountBlocked!false>
        <p>请关闭此页，回到 App 核对当前账号状态后重新开始。</p>
      <#elseif phoneAvailable!false>
        <#if accountAction == "RECOVER_PHONE">
          <p>已确认原账号绑定的微信。验证新的中国大陆手机号后，继续使用原来的家庭、设备和会员。</p>
        <#elseif accountAction == "CHANGE_PHONE">
          <#if (accountStep!'') == "NEW"><p>当前手机号已验证。请验证新手机号，原家庭、订单和会员会保留。</p><#else><p>先验证此账号当前使用的手机号，再验证新手机号。</p></#if>
        <#elseif accountAction == "BIND_WECHAT"><p>验证当前手机号后，将刚才授权的微信绑定到此账号。</p>
        <#elseif accountAction == "UNBIND_WECHAT"><p>验证当前手机号后解绑微信。手机号仍可登录，其他设备需重新登录。</p></#if>
        <#if (accountPhoneMasked!'')?has_content><p>原账号手机号：${accountPhoneMasked}</p></#if>
        <form action="${url.loginAction}" method="post">
          <label for="phone"><#if (accountStep!'') == "NEW">新手机号<#else>当前手机号</#if></label>
          <input id="phone" name="phone" type="tel" inputmode="tel" autocomplete="tel-national" maxlength="14" value="<#if (accountStep!'') == 'NEW'>${accountNewPhone!''}</#if>" required class="${properties.kcInputClass!}" />
          <button type="submit" name="action" value="send" class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!}"><#if codeSent!false>重新发送验证码<#else>获取验证码</#if></button>
        </form>
        <#if codeSent!false>
          <form action="${url.loginAction}" method="post">
            <p>验证码已发送，有效期 5 分钟。</p>
            <label for="code">短信验证码</label>
            <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required class="${properties.kcInputClass!}" />
            <button type="submit" name="action" value="verify" class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!}"><#if accountAction == "CHANGE_PHONE" && (accountStep!'') != "NEW">验证并继续<#elseif accountAction == "UNBIND_WECHAT">验证并解绑<#elseif accountAction == "BIND_WECHAT">验证并绑定<#elseif accountAction == "RECOVER_PHONE">验证并找回<#else>验证并更换</#if></button>
          </form>
        </#if>
      </#if>
    <#elseif phoneAvailable!false>
      <p>首次验证后创建账号。仅验证手机号持有权，家庭开户还需监护人声明。</p>
      <form action="${url.loginAction}" method="post">
        <label for="phone">中国大陆手机号</label>
        <input id="phone" name="phone" type="tel" inputmode="tel" autocomplete="tel-national" maxlength="14" value="${phone!''}" required class="${properties.kcInputClass!}" />
        <button type="submit" name="action" value="send" class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!}"><#if codeSent!false>重新发送验证码<#else>获取验证码</#if></button>
      </form>
      <#if codeSent!false>
        <form action="${url.loginAction}" method="post">
          <p>验证码已发送，有效期 5 分钟。</p>
          <label for="code">短信验证码</label>
          <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required class="${properties.kcInputClass!}" />
          <button type="submit" name="action" value="verify" class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!}">验证并继续</button>
        </form>
      </#if>
    </#if>
  </#if>
</@layout.registrationLayout>
