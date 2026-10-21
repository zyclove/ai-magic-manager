package com.aimanager.identity;

import org.keycloak.Config;
import org.keycloak.authentication.*;
import org.keycloak.models.*;
import org.keycloak.provider.ProviderConfigProperty;
import java.util.List;
import java.util.Map;
import java.net.http.HttpClient;
import java.time.Duration;
import java.io.IOException;

public final class ConsumerAuthenticatorFactory implements AuthenticatorFactory {
  public static final String ID="consumer-cn-phone-wechat";
  private record Providers(Map<String,String> configuration,PhoneOtp.Sender sender,WechatNative.Transport wechat){}
  private volatile Providers providers;
  public Authenticator create(KeycloakSession session){
    var current=providers;
    if(current==null)throw new IllegalStateException("Consumer authenticator factory is not initialized");
    return new ConsumerAuthenticator(current.configuration(),current.sender(),current.wechat());
  }
  public String getId(){return ID;}
  public String getDisplayType(){return "China consumer phone / native WeChat";}
  public String getReferenceCategory(){return "consumer-cn";}
  public boolean isConfigurable(){return false;}
  public AuthenticationExecutionModel.Requirement[] getRequirementChoices(){return new AuthenticationExecutionModel.Requirement[]{AuthenticationExecutionModel.Requirement.REQUIRED,AuthenticationExecutionModel.Requirement.DISABLED};}
  public boolean isUserSetupAllowed(){return false;}
  public String getHelpText(){return "China SMS verification and native mobile WeChat OAuth. Requires protected phone attributes and server environment credentials.";}
  public List<ProviderConfigProperty> getConfigProperties(){return List.of();}
  public void init(Config.Scope config){
    var configuration=ConsumerProviderRuntime.current().configuration();
    var client=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).followRedirects(HttpClient.Redirect.NEVER).build();
    PhoneOtp.Sender sender;
    if(ConsumerConfiguration.phoneAvailable(configuration)){
      sender=new AliyunSms(configuration.get("ALIYUN_SMS_ACCESS_KEY_ID"),configuration.get("ALIYUN_SMS_ACCESS_KEY_SECRET"),configuration.get("ALIYUN_SMS_SIGN_NAME"),configuration.get("ALIYUN_SMS_TEMPLATE_CODE"),configuration.get("ALIYUN_SMS_SECURITY_TOKEN"),AliyunSms.httpTransport(client));
    }else{
      sender=(phone,code)->{throw new IOException("SMS provider is not configured");};
    }
    providers=new Providers(configuration,sender,WechatNative.httpTransport(client));
  }
  public void postInit(KeycloakSessionFactory factory){}
  // Java 17 HttpClient has no close operation; both adapters borrow its managed resources.
  public void close(){}
}
