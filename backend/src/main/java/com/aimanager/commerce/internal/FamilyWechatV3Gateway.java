package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import com.aimanager.commerce.FamilySalesGate;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.interfaces.RSAKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpStatus;

/** WeChat v3 direct merchant boundary. Pinned external keys; no credentials in source or logs. */
final class FamilyWechatV3Gateway implements FamilyPaymentGateway {
  private final String appId;
  private final String merchantId;
  private final String merchantSerial;
  private final String platformKeyId;
  private final PrivateKey merchantKey;
  private final PublicKey platformKey;
  private final byte[] apiKey;
  private final String notifyUrl;
  private final boolean salesEnabled;
  private final FamilySalesGate salesGate;
  private final ObjectMapper json;
  private final Clock clock;
  private final java.net.http.HttpClient http;

  FamilyWechatV3Gateway(String appId, String merchantId, String merchantSerial, PrivateKey merchantKey,
      String platformKeyId, PublicKey platformKey, byte[] apiKey, String notifyUrl,
      boolean salesEnabled, ObjectMapper json, Clock clock) {
    this(appId,merchantId,merchantSerial,merchantKey,platformKeyId,platformKey,apiKey,notifyUrl,
        salesEnabled,json,clock,java.net.http.HttpClient.newBuilder().connectTimeout(java.time.Duration.ofSeconds(3))
            .followRedirects(java.net.http.HttpClient.Redirect.NEVER).build(),()->false);
  }

  FamilyWechatV3Gateway(String appId, String merchantId, String merchantSerial, PrivateKey merchantKey,
      String platformKeyId, PublicKey platformKey, byte[] apiKey, String notifyUrl,
      boolean salesEnabled, ObjectMapper json, Clock clock, java.net.http.HttpClient http) {
    this(appId,merchantId,merchantSerial,merchantKey,platformKeyId,platformKey,apiKey,notifyUrl,salesEnabled,json,clock,http,()->false);
  }

  FamilyWechatV3Gateway(String appId,String merchantId,String merchantSerial,PrivateKey merchantKey,
      String platformKeyId,PublicKey platformKey,byte[] apiKey,String notifyUrl,
      boolean salesEnabled,ObjectMapper json,Clock clock,FamilySalesGate salesGate){
    this(appId,merchantId,merchantSerial,merchantKey,platformKeyId,platformKey,apiKey,notifyUrl,salesEnabled,json,clock,
        java.net.http.HttpClient.newBuilder().connectTimeout(java.time.Duration.ofSeconds(3)).followRedirects(java.net.http.HttpClient.Redirect.NEVER).build(),salesGate);
  }

  FamilyWechatV3Gateway(String appId,String merchantId,String merchantSerial,PrivateKey merchantKey,
      String platformKeyId,PublicKey platformKey,byte[] apiKey,String notifyUrl,
      boolean salesEnabled,ObjectMapper json,Clock clock,java.net.http.HttpClient http,FamilySalesGate salesGate){
    this.appId=appId; this.merchantId=merchantId; this.merchantSerial=merchantSerial;
    this.merchantKey=merchantKey; this.platformKeyId=platformKeyId; this.platformKey=platformKey;
    this.apiKey=apiKey.clone(); this.notifyUrl=notifyUrl; this.salesEnabled=salesEnabled;
    this.salesGate=java.util.Objects.requireNonNull(salesGate);
    this.json=json; this.clock=clock;
    this.http=http;
  }

  /** Missing or malformed credential configuration exposes explicit unavailability. */
  static FamilyWechatV3Gateway configured(Environment env, ObjectMapper json, Clock clock) {
    return configured(env,json,clock,()->false);
  }

  static FamilyWechatV3Gateway configured(Environment env,ObjectMapper json,Clock clock,FamilySalesGate salesGate){
    if (!env.getProperty("manager.family.wechat.enabled",Boolean.class,false)) return null;
    try {
      String app = env.getRequiredProperty("manager.family.wechat.app-id");
      String merchant = env.getRequiredProperty("manager.family.wechat.merchant-id");
      String serial = env.getRequiredProperty("manager.family.wechat.merchant-serial");
      String keyId = env.getRequiredProperty("manager.family.wechat.platform-key-id");
      String callback = env.getRequiredProperty("manager.family.wechat.notify-url");
      var uri = java.net.URI.create(callback);
      if (!app.matches("[A-Za-z0-9_-]{1,32}") || !merchant.matches("[0-9]{6,32}")
          || !serial.matches("[A-Za-z0-9_]{1,128}") || !keyId.matches("[A-Za-z0-9_]{1,128}")
          || !"https".equals(uri.getScheme()) || uri.getHost()==null || uri.getUserInfo()!=null
          || uri.getQuery()!=null || uri.getFragment()!=null) return null;
      var factory = KeyFactory.getInstance("RSA");
      var privateKey = factory.generatePrivate(new PKCS8EncodedKeySpec(pem(env.getRequiredProperty("manager.family.wechat.merchant-key-file"),"PRIVATE KEY")));
      var publicKey = factory.generatePublic(new X509EncodedKeySpec(pem(env.getRequiredProperty("manager.family.wechat.platform-key-file"),"PUBLIC KEY")));
      if (((RSAKey)privateKey).getModulus().bitLength()<2048 || ((RSAKey)publicKey).getModulus().bitLength()<2048) return null;
      byte[] api = Files.readString(Path.of(env.getRequiredProperty("manager.family.wechat.api-v3-key-file")),StandardCharsets.UTF_8).strip().getBytes(StandardCharsets.UTF_8);
      if (api.length!=32) return null;
      return new FamilyWechatV3Gateway(app,merchant,serial,privateKey,keyId,publicKey,api,callback,
          env.getProperty("manager.family.sales-enabled",Boolean.class,false),json,clock,salesGate);
    } catch (IOException | GeneralSecurityException | IllegalArgumentException | IllegalStateException invalid) {
      return null;
    }
  }

  private static byte[] pem(String file, String label) throws IOException {
    if (Files.size(Path.of(file))>16384) throw new IllegalArgumentException("Invalid key file");
    String value = Files.readString(Path.of(file),StandardCharsets.US_ASCII);
    if (!value.contains("-----BEGIN "+label+"-----") || !value.contains("-----END "+label+"-----"))
      throw new IllegalArgumentException("Invalid key file");
    return Base64.getDecoder().decode(value.replace("-----BEGIN "+label+"-----","").replace("-----END "+label+"-----","").replaceAll("\\s",""));
  }

  @Override public boolean available() { return salesEnabled && saleEvidenceAllowed(); }
  @Override public boolean verificationAvailable() { return true; }
  @Override public boolean refundsAvailable() { return true; }

  @Override
  public AppPayment createAppPayment(PaymentCommand command) {
    if (!salesEnabled) throw FamilyCommerceConfiguration.unavailable();
    if (!saleEvidenceAllowed()) throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"FAMILY_SALES_CLOSED");
    reference(command.merchantOrderId());
    if (command.priceMinor()<=0 || !"CNY".equals(command.currency()) || command.expiresAt()<=clock.millis())
      throw DomainException.invalid("INVALID_WECHAT_PAYMENT_COMMAND");
    JsonNode response = request("POST","/v3/pay/transactions/app",Map.of("appid",appId,"mchid",merchantId,
        "description",command.description(),"out_trade_no",command.merchantOrderId(),"notify_url",notifyUrl,
        "time_expire",java.time.Instant.ofEpochMilli(command.expiresAt()).atOffset(java.time.ZoneOffset.ofHours(8)).toString(),
        "amount",Map.of("total",command.priceMinor(),"currency",command.currency())));
    String prepay=text(response,"prepay_id");
    String timestamp=Long.toString(clock.millis()/1000), nonce=nonce();
    return new AppPayment(Map.of("appId",appId,"partnerId",merchantId,"prepayId",prepay,"packageValue","Sign=WXPay",
        "nonceStr",nonce,"timeStamp",timestamp,"sign",sign(appId+"\n"+timestamp+"\n"+nonce+"\n"+prepay+"\n")));
  }
  private boolean saleEvidenceAllowed(){
    try{return salesGate.allowed();}catch(RuntimeException unavailable){return false;}
  }

  @Override
  public PaymentEvidence queryPayment(String id) {
    reference(id);
    JsonNode response=request("GET","/v3/pay/transactions/out-trade-no/"+id+"?mchid="+merchantId,null);
    PaymentEvidence evidence=payment(response,FamilySubscriptionService.hash(response.toString()));
    if (!id.equals(evidence.merchantOrderId())) throw invalid();
    return evidence;
  }

  @Override
  public void closePayment(String id) {
    reference(id);
    request("POST","/v3/pay/transactions/out-trade-no/"+id+"/close",Map.of("mchid",merchantId),true,false);
  }

  @Override
  public void submitRefund(RefundCommand command) {
    reference(command.merchantRefundId()); reference(command.merchantOrderId());
    if (command.providerTransactionId()==null || !command.providerTransactionId().matches("[A-Za-z0-9_-]{1,80}")
        || command.priceMinor()<=0 || !"CNY".equals(command.currency())) throw DomainException.invalid("INVALID_WECHAT_REFUND_COMMAND");
    JsonNode response=request("POST","/v3/refund/domestic/refunds",Map.of("transaction_id",command.providerTransactionId(),
        "out_refund_no",command.merchantRefundId(),"reason","家庭会员全额退款","notify_url",notifyUrl,
        "amount",Map.of("refund",command.priceMinor(),"total",command.priceMinor(),"currency",command.currency())));
    RefundEvidence evidence=refund(response,FamilySubscriptionService.hash(response.toString()),false);
    if (!command.merchantRefundId().equals(evidence.merchantRefundId()) || !command.merchantOrderId().equals(evidence.merchantOrderId())
        || !command.providerTransactionId().equals(evidence.providerTransactionId()) || command.priceMinor()!=evidence.priceMinor()
        || !command.currency().equals(evidence.currency())) throw invalid();
  }

  @Override
  public RefundEvidence queryRefund(String id) {
    reference(id);
    JsonNode response=request("GET","/v3/refund/domestic/refunds/"+id,null);
    RefundEvidence evidence=refund(response,FamilySubscriptionService.hash(response.toString()),false);
    if (!id.equals(evidence.merchantRefundId())) throw invalid();
    return evidence;
  }

  String billMerchantId(){return merchantId;}
  String billAppId(){return appId;}
  JsonNode signedBillRead(String target) {
    if(target==null||!target.matches("/v3/bill/tradebill\\?bill_date=[0-9]{4}-[0-9]{2}-[0-9]{2}&bill_type=ALL"))
      throw DomainException.invalid("INVALID_WECHAT_BILL_REQUEST");
    return request("GET",target,null,false,true);
  }

  byte[] downloadBill(java.net.URI uri,int maxBytes) {
    if(uri==null||!"https".equals(uri.getScheme())||!"api.mch.weixin.qq.com".equals(uri.getHost())
        ||uri.getUserInfo()!=null||uri.getFragment()!=null||(uri.getPort()!=-1&&uri.getPort()!=443)
        ||!java.util.Set.of("/v3/billdownload/file","/v3/bill/downloadurl").contains(uri.getRawPath())
        ||uri.getRawQuery()==null||!uri.getRawQuery().matches("token=[A-Za-z0-9_%+\\-=.]{1,4096}")
        ||maxBytes<1||maxBytes>32*1024*1024)throw DomainException.invalid("INVALID_WECHAT_BILL_DOWNLOAD");
    String target=uri.getRawPath()+"?"+uri.getRawQuery();
    try {
      var response=http.send(signedRequest("GET",target,"",uri),boundedBytes(maxBytes));
      if(response.statusCode()!=200||response.body()==null||response.body().length>maxBytes)throw FamilyCommerceConfiguration.unavailable();
      return response.body();
    } catch(IOException failure){throw FamilyCommerceConfiguration.unavailable();}
    catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw FamilyCommerceConfiguration.unavailable();}
  }

  private JsonNode request(String method,String target,Object payload) {return request(method,target,payload,false,false);}
  private JsonNode request(String method,String target,Object payload,boolean closing,boolean bill) {
    String body;
    try { body=payload==null ? "" : json.writeValueAsString(payload); }
    catch (IOException invalid) { throw FamilyCommerceConfiguration.unavailable(); }
    var request=signedRequest(method,target,body,java.net.URI.create("https://api.mch.weixin.qq.com"+target));
    try {
      var response=http.send(request,boundedBytes(65536));
      if(response.body()==null||response.body().length>65536)throw FamilyCommerceConfiguration.unavailable();
      String raw=new String(response.body(),StandardCharsets.UTF_8);
      Map<String,String> headers=new java.util.HashMap<>();
      response.headers().map().forEach((name,values)->{if(values.size()==1)headers.put(name,values.get(0));});
      verifySignature(headers,raw);
      JsonNode value=raw.isEmpty()?json.createObjectNode():parse(raw);
      if(response.statusCode()<200||response.statusCode()>=300) {
        String code=value.path("code").asText();
        if(response.statusCode()==404&&"RESOURCE_NOT_EXISTS".equals(code))throw new FamilyPaymentGateway.ResourceMissing();
        if(bill&&java.util.Set.of("NO_STATEMENT_EXIST","STATEMENT_CREATING").contains(code))throw new FamilyBillGateway.Unavailable(code);
        throw FamilyCommerceConfiguration.unavailable();
      }
      if(closing&&response.statusCode()!=204)throw FamilyCommerceConfiguration.unavailable();
      if(!closing&&response.statusCode()!=200)throw FamilyCommerceConfiguration.unavailable();
      return value;
    } catch(IOException unavailable){throw FamilyCommerceConfiguration.unavailable();}
    catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw FamilyCommerceConfiguration.unavailable();}
  }

  /** 下载时即限制大小；完整 body 处理包含在 HttpClient 请求超时中。 */
  private static java.net.http.HttpResponse.BodyHandler<byte[]> boundedBytes(int limit) {
    return ignored->new java.net.http.HttpResponse.BodySubscriber<byte[]>() {
      private final java.net.http.HttpResponse.BodySubscriber<byte[]> delegate=java.net.http.HttpResponse.BodySubscribers.ofByteArray();
      private java.util.concurrent.Flow.Subscription subscription;
      private long received;
      private boolean failed;
      @Override public java.util.concurrent.CompletionStage<byte[]> getBody(){return delegate.getBody();}
      @Override public void onSubscribe(java.util.concurrent.Flow.Subscription value){subscription=value;delegate.onSubscribe(value);}
      @Override public void onNext(java.util.List<java.nio.ByteBuffer> chunks){
        if(failed)return;
        for(var chunk:chunks)received+=chunk.remaining();
        if(received>limit){failed=true;subscription.cancel();delegate.onError(new IOException("Provider response exceeds limit"));return;}
        delegate.onNext(chunks);
      }
      @Override public void onError(Throwable failure){if(!failed){failed=true;delegate.onError(failure);}}
      @Override public void onComplete(){if(!failed)delegate.onComplete();}
    };
  }

  private java.net.http.HttpRequest signedRequest(String method,String target,String body,java.net.URI uri) {
    String timestamp=Long.toString(clock.millis()/1000), nonce=nonce();
    String signed=sign(method+"\n"+target+"\n"+timestamp+"\n"+nonce+"\n"+body+"\n");
    String authorization="WECHATPAY2-SHA256-RSA2048 mchid=\""+merchantId+"\",nonce_str=\""+nonce
        +"\",timestamp=\""+timestamp+"\",serial_no=\""+merchantSerial+"\",signature=\""+signed+"\"";
    return java.net.http.HttpRequest.newBuilder(uri)
        .timeout(java.time.Duration.ofSeconds(5)).header("Authorization",authorization).header("Accept","application/json")
        .header("Content-Type","application/json").header("Wechatpay-Serial",platformKeyId)
        .method(method,body.isEmpty() ? java.net.http.HttpRequest.BodyPublishers.noBody() : java.net.http.HttpRequest.BodyPublishers.ofString(body,StandardCharsets.UTF_8)).build();
  }

  private String sign(String message) {
    try {
      var signature=Signature.getInstance("SHA256withRSA"); signature.initSign(merchantKey);
      signature.update(message.getBytes(StandardCharsets.UTF_8)); return Base64.getEncoder().encodeToString(signature.sign());
    } catch (GeneralSecurityException unavailable) { throw FamilyCommerceConfiguration.unavailable(); }
  }
  private static String nonce() { return java.util.UUID.randomUUID().toString().replace("-",""); }
  private static void reference(String value) {
    if (value==null || !value.matches("[0-9a-f]{32}")) throw DomainException.invalid("INVALID_WECHAT_MERCHANT_REFERENCE");
  }

  @Override
  public Notification verifyNotification(Map<String,String> headers, String rawBody) {
    verifySignature(headers,rawBody);
    JsonNode envelope = parse(rawBody);
    String eventId = text(envelope,"id");
    String eventType = text(envelope,"event_type");
    if (!"encrypt-resource".equals(text(envelope,"resource_type"))) throw invalid();
    JsonNode resource = envelope.path("resource");
    if (!"AEAD_AES_256_GCM".equals(text(resource,"algorithm"))) throw invalid();
    String decrypted;
    try {
      var cipher = Cipher.getInstance("AES/GCM/NoPadding");
      byte[] nonce = text(resource,"nonce").getBytes(StandardCharsets.UTF_8);
      if (nonce.length!=12) throw invalid();
      cipher.init(Cipher.DECRYPT_MODE,new SecretKeySpec(apiKey,"AES"),new GCMParameterSpec(128,nonce));
      String aad = resource.has("associated_data") ? resource.path("associated_data").asText() : "";
      cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
      decrypted = new String(cipher.doFinal(Base64.getDecoder().decode(text(resource,"ciphertext"))),StandardCharsets.UTF_8);
    } catch (GeneralSecurityException | IllegalArgumentException malformed) { throw invalid(); }
    JsonNode value = parse(decrypted);
    requireMerchant(value);
    String evidence = FamilySubscriptionService.hash(rawBody);
    if ("TRANSACTION.SUCCESS".equals(eventType)) {
      PaymentEvidence payment = payment(value,evidence);
      if (!"SUCCESS".equals(payment.tradeState())) throw invalid();
      return new Notification(eventId,"PAYMENT",evidence,payment,null);
    }
    if (java.util.Set.of("REFUND.SUCCESS","REFUND.CLOSED","REFUND.ABNORMAL").contains(eventType)) {
      RefundEvidence refund = refund(value,evidence,true);
      if (!eventType.equals("REFUND."+refund.refundState())) throw invalid();
      return new Notification(eventId,"REFUND",evidence,null,refund);
    }
    throw invalid();
  }

  private void verifySignature(Map<String,String> headers, String body) {
    try {
      String timestamp = header(headers,"Wechatpay-Timestamp");
      long seconds = Long.parseLong(timestamp);
      long current = clock.millis()/1000;
      if (seconds<current-300 || seconds>current+300) throw invalid();
      if (!platformKeyId.equals(header(headers,"Wechatpay-Serial"))) throw invalid();
      String nonce = header(headers,"Wechatpay-Nonce");
      if (nonce.length()>128 || nonce.chars().anyMatch(Character::isISOControl)) throw invalid();
      String encoded = header(headers,"Wechatpay-Signature");
      if (encoded.length()>2048) throw invalid();
      var signature = Signature.getInstance("SHA256withRSA");
      signature.initVerify(platformKey);
      signature.update((timestamp+"\n"+nonce+"\n"+body+"\n").getBytes(StandardCharsets.UTF_8));
      if (!signature.verify(Base64.getDecoder().decode(encoded))) throw invalid();
    } catch (GeneralSecurityException | IllegalArgumentException malformed) { throw invalid(); }
  }

  private static String header(Map<String,String> headers, String name) {
    return headers.entrySet().stream().filter(e->e.getKey().equalsIgnoreCase(name)).map(Map.Entry::getValue)
        .filter(v->v!=null && !v.isBlank()).findFirst().orElseThrow(FamilyWechatV3Gateway::invalid);
  }

  private PaymentEvidence payment(JsonNode value, String evidence) {
    requireMerchant(value);
    if (!appId.equals(text(value,"appid"))) throw invalid();
    String state = text(value,"trade_state");
    String transaction = "SUCCESS".equals(state) ? text(value,"transaction_id") : null;
    JsonNode amount=value.path("amount");
    if(!amount.isMissingNode()&&!amount.isNull()&&!amount.isObject())throw invalid();
    Integer total=amount.hasNonNull("total")?integer(amount,"total"):null;
    String currency=amount.hasNonNull("currency")?text(amount,"currency"):null;
    // 未支付/已关闭应答允许省略金额；成功付款必须保留完整核验材料。
    if("SUCCESS".equals(state)&&(total==null||currency==null))throw invalid();
    return new PaymentEvidence(text(value,"out_trade_no"),transaction,total,
        currency,state,"SUCCESS".equals(state) ? time(value,"success_time") : 0,evidence);
  }

  private RefundEvidence refund(JsonNode value, String evidence, boolean notification) {
    if (notification) requireMerchant(value);
    String state = text(value,notification ? "refund_status" : "status");
    JsonNode amount = value.path("amount");
    int total = integer(amount,"total"), refunded = integer(amount,"refund");
    if (total!=refunded) throw invalid();
    String currency = notification ? "CNY" : text(amount,"currency");
    return new RefundEvidence(text(value,"out_refund_no"),text(value,"out_trade_no"),text(value,"refund_id"),
        text(value,"transaction_id"),refunded,currency,state,"SUCCESS".equals(state) ? time(value,"success_time") : 0,evidence,
        value.hasNonNull("create_time")?time(value,"create_time"):null);
  }

  private void requireMerchant(JsonNode value) { if (!merchantId.equals(text(value,"mchid"))) throw invalid(); }
  private JsonNode parse(String body) {
    try { JsonNode value=json.readTree(body); if (value==null || !value.isObject()) throw invalid(); return value; }
    catch (IOException malformed) { throw invalid(); }
  }
  private static String text(JsonNode value, String field) {
    JsonNode child=value.path(field);
    if (!child.isTextual() || child.asText().isBlank()) throw invalid();
    return child.asText();
  }
  private static int integer(JsonNode value, String field) {
    JsonNode child=value.path(field);
    if (!child.isIntegralNumber() || !child.canConvertToInt() || child.asInt()<0) throw invalid();
    return child.asInt();
  }
  private static long time(JsonNode value, String field) {
    try { return OffsetDateTime.parse(text(value,field)).toInstant().toEpochMilli(); }
    catch (java.time.DateTimeException malformed) { throw invalid(); }
  }
  private static DomainException invalid() { return new DomainException(HttpStatus.UNAUTHORIZED,"WECHAT_SIGNATURE_OR_EVIDENCE_INVALID"); }
}
