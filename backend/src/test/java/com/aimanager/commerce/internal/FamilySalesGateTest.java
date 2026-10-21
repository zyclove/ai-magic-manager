package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.time.Clock;
import java.net.http.HttpClient;
import java.util.concurrent.atomic.AtomicBoolean;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import org.springframework.mock.env.MockEnvironment;
import org.junit.jupiter.api.Test;

/** 生产默认关闭；密钥与商户开关存在不构成真实发布验收。 */
class FamilySalesGateTest {
  @Test void booleanSwitchAloneCannotOpenSalesOrStartNewPayment()throws Exception{
    var generator=KeyPairGenerator.getInstance("RSA");generator.initialize(2048);var merchant=generator.generateKeyPair();var platform=generator.generateKeyPair();
    var gateway=new FamilyWechatV3Gateway("wx-fixture","1900000001","AABBCC",merchant.getPrivate(),"PUB_KEY_ID_FIXTURE",platform.getPublic(),
        "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8),"https://merchant.example/callback",true,new ObjectMapper(),Clock.systemUTC());
    assertThat(gateway.available()).isFalse();
    assertThatThrownBy(()->gateway.createAppPayment(new FamilyPaymentGateway.PaymentCommand("a".repeat(32),1900,"CNY","fixture",System.currentTimeMillis()+60000)))
        .hasMessage("FAMILY_SALES_CLOSED");
    assertThat(gateway.verificationAvailable()).isTrue();assertThat(gateway.refundsAvailable()).isTrue();assertThat(new FamilyWechatBillGateway(gateway).available()).isTrue();
  }
  @Test void gateRevocationAndGateFailureCloseNewPaymentsBeforeAnyNetworkRequest()throws Exception{
    var generator=KeyPairGenerator.getInstance("RSA");generator.initialize(2048);var merchant=generator.generateKeyPair();var platform=generator.generateKeyPair();
    var http=org.mockito.Mockito.mock(HttpClient.class);var allowed=new AtomicBoolean(true);
    var gateway=new FamilyWechatV3Gateway("wx-fixture","1900000001","AABBCC",merchant.getPrivate(),"PUB_KEY_ID_FIXTURE",platform.getPublic(),
        "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8),"https://merchant.example/callback",true,new ObjectMapper(),Clock.systemUTC(),http,allowed::get);
    assertThat(gateway.available()).isTrue();allowed.set(false);assertThat(gateway.available()).isFalse();
    var command=new FamilyPaymentGateway.PaymentCommand("a".repeat(32),1900,"CNY","fixture",System.currentTimeMillis()+60000);
    assertThatThrownBy(()->gateway.createAppPayment(command)).hasMessage("FAMILY_SALES_CLOSED");
    var unavailable=new FamilyWechatV3Gateway("wx-fixture","1900000001","AABBCC",merchant.getPrivate(),"PUB_KEY_ID_FIXTURE",platform.getPublic(),
        "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8),"https://merchant.example/callback",true,new ObjectMapper(),Clock.systemUTC(),http,
        ()->{throw new IllegalStateException("private fixture failure");});
    assertThat(unavailable.available()).isFalse();assertThatThrownBy(()->unavailable.createAppPayment(command)).hasMessage("FAMILY_SALES_CLOSED");
    org.mockito.Mockito.verifyNoInteractions(http);
  }
  @Test void configuredFactoryKeepsBillAdapterAvailableWhileBothSalesChecksStayClosed()throws Exception{
    var generator=KeyPairGenerator.getInstance("RSA");generator.initialize(2048);var merchant=generator.generateKeyPair();var platform=generator.generateKeyPair();
    Path root=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"sales-gate-keys-");
    try{
      Files.writeString(root.resolve("merchant.pem"),pem("PRIVATE KEY",merchant.getPrivate().getEncoded()));
      Files.writeString(root.resolve("platform.pem"),pem("PUBLIC KEY",platform.getPublic().getEncoded()));Files.writeString(root.resolve("api-key"),"0123456789abcdef0123456789abcdef");
      var env=new MockEnvironment().withProperty("manager.family.wechat.enabled","true").withProperty("manager.family.sales-enabled","true")
          .withProperty("manager.family.wechat.app-id","wx-fixture").withProperty("manager.family.wechat.merchant-id","1900000001")
          .withProperty("manager.family.wechat.merchant-serial","AABBCC").withProperty("manager.family.wechat.platform-key-id","PUB_KEY_ID_FIXTURE")
          .withProperty("manager.family.wechat.notify-url","https://merchant.example/callback").withProperty("manager.family.wechat.merchant-key-file",root.resolve("merchant.pem").toString())
          .withProperty("manager.family.wechat.platform-key-file",root.resolve("platform.pem").toString()).withProperty("manager.family.wechat.api-v3-key-file",root.resolve("api-key").toString());
      var payment=new FamilyCommerceConfiguration().familyPaymentGateway(env,new ObjectMapper(),Clock.systemUTC(),()->false);
      assertThat(payment).isInstanceOf(FamilyWechatV3Gateway.class);assertThat(payment.available()).isFalse();
      assertThat(payment.verificationAvailable()).isTrue();assertThat(payment.refundsAvailable()).isTrue();assertThat(new FamilyBillConfiguration().familyBillGateway(payment).available()).isTrue();
      assertThat(FamilyWechatV3Gateway.configured(env,new ObjectMapper(),Clock.systemUTC()).available()).isFalse();
      assertThatThrownBy(()->payment.createAppPayment(new FamilyPaymentGateway.PaymentCommand("a".repeat(32),1900,"CNY","fixture",System.currentTimeMillis()+60000)))
          .hasMessage("FAMILY_SALES_CLOSED");
    }finally{for(String file:new String[]{"merchant.pem","platform.pem","api-key"})Files.deleteIfExists(root.resolve(file));Files.deleteIfExists(root);}
  }
  private static String pem(String type,byte[] bytes){return "-----BEGIN "+type+"-----\n"+Base64.getMimeEncoder(64,new byte[]{'\n'}).encodeToString(bytes)+"\n-----END "+type+"-----\n";}
}
