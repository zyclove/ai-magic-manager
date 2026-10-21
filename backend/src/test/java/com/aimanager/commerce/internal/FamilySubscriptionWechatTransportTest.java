package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Flow;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Pattern;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/** Inject only HTTP transport; exercise the production protocol and real RSA signatures. */
class FamilySubscriptionWechatTransportTest {
  private static final String ID="1234567890abcdef1234567890abcdef";
  private static final String REFUND="abcdef1234567890abcdef1234567890";
  private static final Instant NOW=Instant.parse("2026-10-15T04:00:00Z");
  private final ObjectMapper json=new ObjectMapper();
  private KeyPair merchant;
  private KeyPair platform;
  private HttpClient http;
  private FamilyWechatV3Gateway gateway;
  private final AtomicReference<HttpRequest> sent=new AtomicReference<>();

  @BeforeEach
  void keys() throws Exception {
    var generator=KeyPairGenerator.getInstance("RSA"); generator.initialize(2048);
    merchant=generator.generateKeyPair(); platform=generator.generateKeyPair();
    http=mock(HttpClient.class);
    gateway=new FamilyWechatV3Gateway("wx-fixture","1900000001","AABBCC",merchant.getPrivate(),"PUB_KEY_ID_FIXTURE",platform.getPublic(),
        "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8),"https://merchant.example/callback",true,json,
        Clock.fixed(NOW,ZoneOffset.UTC),http,()->true); // 仅协议夹具显式放行，不写入生产验收事实。
  }

  @Test
  void signedUnpaidAndClosedQueriesPermitOptionalAmountButSuccessfulPaymentNeverDoes()throws Exception {
    for(String state:List.of("NOTPAY","CLOSED")){
      response("{\"appid\":\"wx-fixture\",\"mchid\":\"1900000001\",\"out_trade_no\":\""+ID+"\",\"trade_state\":\""+state+"\"}",true);
      var observed=new AtomicReference<FamilyPaymentGateway.PaymentEvidence>();
      assertThatCode(()->observed.set(gateway.queryPayment(ID))).doesNotThrowAnyException();
      var evidence=observed.get();
      assertThat(evidence.tradeState()).isEqualTo(state);assertThat(evidence.priceMinor()).isNull();assertThat(evidence.currency()).isNull();
    }
    response("{\"appid\":\"wx-fixture\",\"mchid\":\"1900000001\",\"out_trade_no\":\""+ID+"\",\"trade_state\":\"SUCCESS\",\"transaction_id\":\"tx-fixture\",\"success_time\":\"2026-10-15T12:00:00+08:00\"}",true);
    assertThatThrownBy(()->gateway.queryPayment(ID)).hasMessage("WECHAT_SIGNATURE_OR_EVIDENCE_INVALID");
  }

  @Test
  void billDownloadSignsOnlyAllowlistedOfficialUrlsAndKeepsAnIndependentSizeBound()throws Exception {
    response("fixture-csv",false);
    byte[] bytes=gateway.downloadBill(java.net.URI.create("https://api.mch.weixin.qq.com/v3/billdownload/file?token=fixture"),1024);
    assertThat(new String(bytes,StandardCharsets.UTF_8)).isEqualTo("fixture-csv");
    verifyAuthorization(sent.get(),"");
    assertThatThrownBy(()->gateway.downloadBill(java.net.URI.create("https://other.example/v3/billdownload/file?token=fixture"),1024)).hasMessage("INVALID_WECHAT_BILL_DOWNLOAD");
    assertThatThrownBy(()->gateway.downloadBill(java.net.URI.create("https://api.mch.weixin.qq.com/v3/billdownload/file?token=fixture&url=evil"),1024)).hasMessage("INVALID_WECHAT_BILL_DOWNLOAD");
    assertThatThrownBy(()->gateway.downloadBill(java.net.URI.create("http://api.mch.weixin.qq.com/v3/billdownload/file?token=fixture"),1024)).hasMessage("INVALID_WECHAT_BILL_DOWNLOAD");
    assertThatThrownBy(()->gateway.downloadBill(java.net.URI.create("https://api.mch.weixin.qq.com/v3/billdownload/file?token=fixture"),4)).hasMessage("FAMILY_PAYMENT_UNAVAILABLE");
  }

  @Test
  @SuppressWarnings("unchecked")
  void providerBodyIsCancelledWhileStreamingBeforeItCanExceedTheBound()throws Exception {
    when(http.send(any(HttpRequest.class),any(HttpResponse.BodyHandler.class))).thenAnswer(call->{
      var handler=(HttpResponse.BodyHandler<byte[]>)call.getArgument(1);
      var subscriber=handler.apply(mock(HttpResponse.ResponseInfo.class));
      var cancelled=new java.util.concurrent.atomic.AtomicBoolean();
      subscriber.onSubscribe(new Flow.Subscription(){public void request(long count){}public void cancel(){cancelled.set(true);}});
      subscriber.onNext(List.of(ByteBuffer.wrap(new byte[65537])));
      assertThat(cancelled).as("超限响应必须在下载过程中取消，不是全部读入后检查").isTrue();
      throw new java.io.IOException("fixture canceled");
    });
    assertThatThrownBy(()->gateway.queryPayment(ID)).hasMessage("FAMILY_PAYMENT_UNAVAILABLE");
  }

  @Test
  void closeUsesTheOriginalMerchantScopeAndAcceptsOnlyTheSigned204Protocol()throws Exception {
    response("",true,204);gateway.closePayment(ID);
    assertThat(sent.get().uri().getPath()).isEqualTo("/v3/pay/transactions/out-trade-no/"+ID+"/close");
    assertThat(json.readTree(body(sent.get())).path("mchid").asText()).isEqualTo("1900000001");
    verifyAuthorization(sent.get(),body(sent.get()));
    response("",true,202);assertThatThrownBy(()->gateway.closePayment(ID)).hasMessage("FAMILY_PAYMENT_UNAVAILABLE");
    response("",false,204);assertThatThrownBy(()->gateway.closePayment(ID)).hasMessage("WECHAT_SIGNATURE_OR_EVIDENCE_INVALID");
  }

  @Test
  void queryRefundUsesSignedProviderCreateTimeForItsAcceptanceDate()throws Exception {
    response(refundJson("PROCESSING").replace("\"status\":", "\"create_time\":\"2026-10-15T11:59:00+08:00\",\"status\":"),true);
    assertThat(gateway.queryRefund(REFUND).acceptedAt()).isEqualTo(NOW.toEpochMilli()-60000);
  }

  @Test
  void billApplicationSharesVerifiedMerchantTransportAndRejectsUnsignedMissingStatements()throws Exception {
    response("{\"hash_type\":\"SHA1\",\"hash_value\":\""+"a".repeat(40)+"\",\"download_url\":\"https://api.mch.weixin.qq.com/v3/billdownload/file?token=fixture\"}",true);
    gateway.signedBillRead("/v3/bill/tradebill?bill_date=2026-10-14&bill_type=ALL");
    verifyAuthorization(sent.get(),"");assertThat(gateway.billMerchantId()).isEqualTo("1900000001");assertThat(gateway.billAppId()).isEqualTo("wx-fixture");
    response("{\"code\":\"NO_STATEMENT_EXIST\"}",true,400);
    assertThatThrownBy(()->gateway.signedBillRead("/v3/bill/tradebill?bill_date=2026-10-14&bill_type=ALL")).isInstanceOf(FamilyBillGateway.Unavailable.class);
    response("{\"code\":\"NO_STATEMENT_EXIST\"}",false,400);
    assertThatThrownBy(()->gateway.signedBillRead("/v3/bill/tradebill?bill_date=2026-10-14&bill_type=ALL")).hasMessage("WECHAT_SIGNATURE_OR_EVIDENCE_INVALID");
    assertThatThrownBy(()->gateway.signedBillRead("/v3/bill/tradebill?bill_date=2026-10-14&bill_type=ALL&evil=x")).hasMessage("INVALID_WECHAT_BILL_REQUEST");
  }

  @Test
  void signedMissingRefundIsDistinguishedFromUnknownOrForgedResponses() throws Exception {
    response("{\"code\":\"RESOURCE_NOT_EXISTS\",\"message\":\"not found\"}",true,404);
    assertThatThrownBy(()->gateway.queryRefund(REFUND)).hasMessage("WECHAT_PROVIDER_RESOURCE_NOT_EXISTS");
    response("{\"code\":\"RESOURCE_NOT_EXISTS\"}",false,404);
    assertThatThrownBy(()->gateway.queryRefund(REFUND)).hasMessage("WECHAT_SIGNATURE_OR_EVIDENCE_INVALID");
  }

  @Test
  void appPrepaySignsOfficialRequestAndReturnsAnIndependentlyVerifiableAppSignature() throws Exception {
    response("{\"prepay_id\":\"wx-prepay-fixture\"}",true);
    var result=new AtomicReference<FamilyPaymentGateway.AppPayment>();
    assertThatCode(()->result.set(gateway.createAppPayment(new FamilyPaymentGateway.PaymentCommand(ID,1900,"CNY","家庭会员",NOW.toEpochMilli()+900000))))
        .doesNotThrowAnyException();
    HttpRequest request=sent.get();
    assertThat(request.uri().toString()).isEqualTo("https://api.mch.weixin.qq.com/v3/pay/transactions/app");
    String body=body(request);
    var payload=json.readTree(body);
    assertThat(payload.path("amount").path("total").asInt()).isEqualTo(1900);
    assertThat(payload.path("amount").path("currency").asText()).isEqualTo("CNY");
    assertThat(payload.path("mchid").asText()).isEqualTo("1900000001");
    assertThat(payload.path("out_trade_no").asText()).isEqualTo(ID);
    assertThat(payload.path("notify_url").asText()).isEqualTo("https://merchant.example/callback");
    verifyAuthorization(request,body);
    Map<String,String> params=result.get().parameters();
    assertThat(params.get("prepayId")).isEqualTo("wx-prepay-fixture");
    assertThat(params.get("packageValue")).isEqualTo("Sign=WXPay");
    assertThat(verify(merchant,"wx-fixture\n"+params.get("timeStamp")+"\n"+params.get("nonceStr")+"\nwx-prepay-fixture\n",params.get("sign"))).isTrue();
  }

  @Test
  void queryUsesSignedMerchantScopeAndRejectsForgedProviderResponses() throws Exception {
    String paid="{\"appid\":\"wx-fixture\",\"mchid\":\"1900000001\",\"out_trade_no\":\""+ID+"\",\"transaction_id\":\"tx-fixture\","
        +"\"trade_state\":\"SUCCESS\",\"success_time\":\"2026-10-15T12:00:00+08:00\",\"amount\":{\"total\":1900,\"currency\":\"CNY\"}}";
    response(paid,true);
    var result=new AtomicReference<FamilyPaymentGateway.PaymentEvidence>();
    assertThatCode(()->result.set(gateway.queryPayment(ID))).doesNotThrowAnyException();
    assertThat(result.get().providerTransactionId()).isEqualTo("tx-fixture");
    assertThat(result.get().paidAt()).isEqualTo(NOW.toEpochMilli());
    assertThat(sent.get().uri().toString()).isEqualTo("https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/"+ID+"?mchid=1900000001");
    verifyAuthorization(sent.get(),"");
    response(paid,false);
    assertThatThrownBy(()->gateway.queryPayment(ID)).isInstanceOf(DomainException.class)
        .hasMessage("WECHAT_SIGNATURE_OR_EVIDENCE_INVALID");
  }

  @Test
  void refundUsesOnlyOriginalTransactionAndFullAmountThenRequiresVerifiedFinalState() throws Exception {
    String processing=refundJson("PROCESSING");
    response(processing,true);
    assertThatCode(()->gateway.submitRefund(new FamilyPaymentGateway.RefundCommand(REFUND,ID,"tx-fixture",1900,"CNY","Requested by owner")))
        .doesNotThrowAnyException();
    assertThat(sent.get().uri().toString()).isEqualTo("https://api.mch.weixin.qq.com/v3/refund/domestic/refunds");
    String raw=body(sent.get());
    var request=json.readTree(raw);
    assertThat(request.path("transaction_id").asText()).isEqualTo("tx-fixture");
    assertThat(request.path("amount").path("refund").asInt()).isEqualTo(1900);
    assertThat(request.path("amount").path("total").asInt()).isEqualTo(1900);
    assertThat(request.has("funds_account")).isFalse();
    assertThat(request.has("user_received_account")).isFalse();
    verifyAuthorization(sent.get(),raw);
    response(refundJson("SUCCESS"),true);
    var result=new AtomicReference<FamilyPaymentGateway.RefundEvidence>();
    assertThatCode(()->result.set(gateway.queryRefund(REFUND))).doesNotThrowAnyException();
    assertThat(result.get().refundState()).isEqualTo("SUCCESS");
    assertThat(result.get().priceMinor()).isEqualTo(1900);
    assertThat(sent.get().uri().getPath()).isEqualTo("/v3/refund/domestic/refunds/"+REFUND);
    verifyAuthorization(sent.get(),"");
  }

  @SuppressWarnings("unchecked")
  private void response(String raw, boolean valid) throws Exception {
    response(raw,valid,200);
  }
  @SuppressWarnings("unchecked")
  private void response(String raw, boolean valid,int code) throws Exception {
    HttpResponse<byte[]> response=mock(HttpResponse.class);
    when(response.statusCode()).thenReturn(code);
    when(response.body()).thenReturn(raw.getBytes(StandardCharsets.UTF_8));
    var sig=Signature.getInstance("SHA256withRSA"); sig.initSign(platform.getPrivate());
    sig.update((NOW.getEpochSecond()+"\nprovider-nonce\n"+raw+(valid ? "" : "tampered")+"\n").getBytes(StandardCharsets.UTF_8));
    when(response.headers()).thenReturn(HttpHeaders.of(Map.of("Wechatpay-Timestamp",List.of(Long.toString(NOW.getEpochSecond())),
        "Wechatpay-Nonce",List.of("provider-nonce"),"Wechatpay-Serial",List.of("PUB_KEY_ID_FIXTURE"),
        "Wechatpay-Signature",List.of(Base64.getEncoder().encodeToString(sig.sign()))),(a,b)->true));
    when(http.send(any(HttpRequest.class),any(HttpResponse.BodyHandler.class))).thenAnswer(invocation->{sent.set(invocation.getArgument(0)); return response;});
  }
  private String refundJson(String state) {
    return "{\"out_refund_no\":\""+REFUND+"\",\"out_trade_no\":\""+ID+"\",\"refund_id\":\"rf-fixture\",\"transaction_id\":\"tx-fixture\","
        +"\"status\":\""+state+"\",\"success_time\":\"2026-10-15T12:00:00+08:00\",\"amount\":{\"refund\":1900,\"total\":1900,\"currency\":\"CNY\"}}";
  }
  private void verifyAuthorization(HttpRequest request,String body) throws Exception {
    String authorization=request.headers().firstValue("Authorization").orElseThrow();
    assertThat(authorization).startsWith("WECHATPAY2-SHA256-RSA2048 ");
    Map<String,String> fields=new java.util.HashMap<>();
    var matcher=Pattern.compile("([a-z_]+)=\"([^\"]+)\"").matcher(authorization);
    while(matcher.find()) fields.put(matcher.group(1),matcher.group(2));
    assertThat(fields.get("mchid")).isEqualTo("1900000001");
    assertThat(fields.get("serial_no")).isEqualTo("AABBCC");
    String target=request.uri().getRawPath()+(request.uri().getRawQuery()==null ? "" : "?"+request.uri().getRawQuery());
    assertThat(verify(merchant,request.method()+"\n"+target+"\n"+fields.get("timestamp")+"\n"+fields.get("nonce_str")+"\n"+body+"\n",fields.get("signature"))).isTrue();
  }
  private boolean verify(KeyPair pair,String message,String encoded) throws Exception {
    var signature=Signature.getInstance("SHA256withRSA"); signature.initVerify(pair.getPublic());
    signature.update(message.getBytes(StandardCharsets.UTF_8)); return signature.verify(Base64.getDecoder().decode(encoded));
  }
  private String body(HttpRequest request) {
    var stream=new ByteArrayOutputStream();
    request.bodyPublisher().orElseThrow().subscribe(new Flow.Subscriber<ByteBuffer>() {
      @Override public void onSubscribe(Flow.Subscription subscription) { subscription.request(Long.MAX_VALUE); }
      @Override public void onNext(ByteBuffer bytes) { while(bytes.hasRemaining()) stream.write(bytes.get()); }
      @Override public void onError(Throwable failure) { throw new AssertionError(failure); }
      @Override public void onComplete() {}
    });
    return stream.toString(StandardCharsets.UTF_8);
  }
}
