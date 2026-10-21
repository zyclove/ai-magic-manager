package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.aimanager.commerce.FamilyAssistedActivationGate;
import com.aimanager.commerce.FamilySalesGate;
import static org.mockito.Mockito.when;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterAll;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.test.web.servlet.MockMvc;

/** Real RSA/GCM locally generated fixtures; no provider requests or merchant credentials. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:family-wechat-crypto;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
@Sql("/family/family-subscription.sql")
class FamilySubscriptionWechatCryptoTest {
  private static final String API_KEY = "0123456789abcdef0123456789abcdef";
  private static final KeyPair PLATFORM;
  private static final Path KEYS;
  static {
    try {
      var rsa = KeyPairGenerator.getInstance("RSA"); rsa.initialize(2048);
      var merchant = rsa.generateKeyPair(); PLATFORM = rsa.generateKeyPair();
      KEYS = Files.createTempDirectory("family-wechat-test-");
      Files.writeString(KEYS.resolve("merchant.pem"), pem("PRIVATE KEY", merchant.getPrivate().getEncoded()));
      Files.writeString(KEYS.resolve("platform.pem"), pem("PUBLIC KEY", PLATFORM.getPublic().getEncoded()));
      Files.writeString(KEYS.resolve("api-key"), API_KEY);
    } catch (Exception invalid) { throw new ExceptionInInitializerError(invalid); }
  }
  @DynamicPropertySource
  static void credentials(DynamicPropertyRegistry registry) {
    registry.add("manager.family.wechat.enabled", () -> true);
    registry.add("manager.family.sales-enabled", () -> true);
    registry.add("manager.family.wechat.app-id", () -> "wx-local-fixture");
    registry.add("manager.family.wechat.merchant-id", () -> "1900000001");
    registry.add("manager.family.wechat.merchant-serial", () -> "AABBCC0011");
    registry.add("manager.family.wechat.merchant-key-file", () -> KEYS.resolve("merchant.pem").toString());
    registry.add("manager.family.wechat.platform-key-id", () -> "PUB_KEY_ID_LOCAL_FIXTURE");
    registry.add("manager.family.wechat.platform-key-file", () -> KEYS.resolve("platform.pem").toString());
    registry.add("manager.family.wechat.api-v3-key-file", () -> KEYS.resolve("api-key").toString());
    registry.add("manager.family.wechat.notify-url", () -> "https://merchant.example/api/v1/payments/wechat/notifications");
  }
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean FamilyAssistedActivationGate activationGate;
  @MockitoBean FamilySalesGate salesGate;
  private String tenant;
  private String orderId;
  private String owner;

  @AfterAll
  static void removeFixtureKeys() throws Exception {
    Files.deleteIfExists(KEYS.resolve("merchant.pem"));
    Files.deleteIfExists(KEYS.resolve("platform.pem"));
    Files.deleteIfExists(KEYS.resolve("api-key"));
    Files.deleteIfExists(KEYS);
  }

  @BeforeEach
  void createUnpaidOrder() throws Exception {
    when(salesGate.allowed()).thenReturn(true); // 本地 RSA/GCM 夹具不作为真实收费验收。
    owner = "crypto-owner-" + UUID.randomUUID();
    var tenantResult = mvc.perform(post("/api/v1/tenants").with(jwt().jwt(t->t.subject(owner))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"Crypto\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn();
    tenant = json.readTree(tenantResult.getResponse().getContentAsString()).path("id").asText();
    String subject=UUID.randomUUID().toString(),device=UUID.randomUUID().toString(),registration=UUID.randomUUID().toString();
    long activatedAt=Instant.now().toEpochMilli();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,?,'UNDER_13',?)",tenant,subject,"Child",activatedAt-1000);
    jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
        +" VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}',?,?)",tenant,device,subject,registration,"Phone","a".repeat(64),activatedAt-1000);
    when(activationGate.verify(tenant,device)).thenReturn(new FamilyAssistedActivationGate.VerifiedActivation(tenant,device,registration,activatedAt,"a".repeat(64)));
    var result = mvc.perform(post(base()+"/orders").with(jwt().jwt(t->t.subject(owner)))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content("{\"planKey\":\"FAMILY_MONTH\"}")).andExpect(status().isOk()).andReturn();
    orderId = json.readTree(result.getResponse().getContentAsString()).path("id").asText();
  }

  @Test
  void configuredGatewayVerifiesRealSignatureAndDecryptsPaymentBeforeGranting() throws Exception {
    mvc.perform(get(base()+"/subscription-offers").with(jwt().jwt(t->t.subject(owner))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.items[0].paymentAvailable").value(true));
    String body = envelope("wx-local-fixture", "1900000001");
    callback(body, body, Instant.now().getEpochSecond(), "PUB_KEY_ID_LOCAL_FIXTURE",200);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,orderId)).isEqualTo("PAID");
  }

  @Test
  void tamperedAndStaleAndUnknownKeyNotificationsCreateNoInbox() throws Exception {
    String body = envelope("wx-local-fixture", "1900000001");
    callback(body+" ",body,Instant.now().getEpochSecond(),"PUB_KEY_ID_LOCAL_FIXTURE",401);
    callback(body,body,Instant.now().getEpochSecond()-3600,"PUB_KEY_ID_LOCAL_FIXTURE",401);
    callback(body,body,Instant.now().getEpochSecond(),"PUB_KEY_ID_OTHER",401);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_inbox WHERE order_id=?",Integer.class,orderId)).isZero();
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?",Integer.class,tenant)).isZero();
  }

  @Test
  void validSignatureCannotAuthorizeAnotherMerchantOrApp() throws Exception {
    String wrongMerchant = envelope("wx-local-fixture","1900000999");
    callback(wrongMerchant,wrongMerchant,Instant.now().getEpochSecond(),"PUB_KEY_ID_LOCAL_FIXTURE",401);
    String wrongApp = envelope("wx-another-app","1900000001");
    callback(wrongApp,wrongApp,Instant.now().getEpochSecond(),"PUB_KEY_ID_LOCAL_FIXTURE",401);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?",Integer.class,tenant)).isZero();
  }

  private String envelope(String appId, String merchant) throws Exception {
    String paid = json.writeValueAsString(Map.of("appid",appId,"mchid",merchant,"out_trade_no",FamilySubscriptionService.merchantId(orderId),
        "transaction_id","wx-provider-"+orderId,"trade_state","SUCCESS","success_time",Instant.now().toString(),
        "amount",Map.of("total",1900,"currency","CNY")));
    String nonce = "123456789012";
    var aes = Cipher.getInstance("AES/GCM/NoPadding");
    aes.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(API_KEY.getBytes(StandardCharsets.UTF_8),"AES"),new GCMParameterSpec(128,nonce.getBytes(StandardCharsets.UTF_8)));
    aes.updateAAD("transaction".getBytes(StandardCharsets.UTF_8));
    String encrypted = Base64.getEncoder().encodeToString(aes.doFinal(paid.getBytes(StandardCharsets.UTF_8)));
    return json.writeValueAsString(Map.of("id","event-"+orderId,"event_type","TRANSACTION.SUCCESS","resource_type","encrypt-resource",
        "create_time",Instant.now().toString(),"summary","支付成功",
        "resource",Map.of("algorithm","AEAD_AES_256_GCM","original_type","transaction","nonce",nonce,"associated_data","transaction","ciphertext",encrypted)));
  }
  private void callback(String body, String signedBody, long timestamp, String serial, int expected) throws Exception {
    var signature = Signature.getInstance("SHA256withRSA"); signature.initSign(PLATFORM.getPrivate());
    signature.update((timestamp+"\nfixture-nonce\n"+signedBody+"\n").getBytes(StandardCharsets.UTF_8));
    mvc.perform(post("/api/v1/payments/wechat/notifications").header("Wechatpay-Timestamp",Long.toString(timestamp))
        .header("Wechatpay-Nonce","fixture-nonce").header("Wechatpay-Serial",serial)
        .header("Wechatpay-Signature",Base64.getEncoder().encodeToString(signature.sign()))
        .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().is(expected));
  }
  private static String pem(String label, byte[] value) { return "-----BEGIN "+label+"-----\n"+Base64.getMimeEncoder(64,new byte[]{10}).encodeToString(value)+"\n-----END "+label+"-----\n"; }
  private String base() { return "/api/v1/tenants/"+tenant; }
}
