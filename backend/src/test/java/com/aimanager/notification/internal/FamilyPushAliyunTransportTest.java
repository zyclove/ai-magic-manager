package com.aimanager.notification.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.net.*;
import java.net.http.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import java.util.concurrent.Flow;
import java.util.concurrent.atomic.AtomicReference;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

/** Real RPC signing and payload; HTTP is the only replaced boundary. No actual push is sent. */
class FamilyPushAliyunTransportTest {
  final AtomicReference<HttpRequest> sent=new AtomicReference<>();
  final ObjectMapper json=new ObjectMapper();
  final HttpClient http=mock(HttpClient.class);
  FamilyPushAliyunGateway gateway;
  final String delivery="83111111-1111-4111-8111-111111111111",event="84111111-1111-4111-8111-111111111111";
  @BeforeEach void gateway() {
    gateway=new FamilyPushAliyunGateway("test-access-id","test-access-secret","23267207","family_updates",json,
        Clock.fixed(Instant.parse("2026-10-15T04:00:00Z"),ZoneOffset.UTC),http);
  }
  @Test void signsOnlyOfficialDomesticDeviceTargetAndCorrelatesStableDeliveryId() throws Exception {
    response(200,"{\"RequestId\":\"fixture-request\",\"MessageId\":\"501029\"}");
    assertThat(gateway.send(command()).providerMessageId()).isEqualTo("501029");
    var request=sent.get();
    assertThat(request.uri()).isEqualTo(URI.create("https://cloudpush.aliyuncs.com/"));
    assertThat(request.method()).isEqualTo("POST");
    var params=parse(body(request));
    assertThat(params).containsEntry("Action","Push").containsEntry("Version","2016-08-01")
        .containsEntry("AppKey","23267207").containsEntry("Target","DEVICE")
        .containsEntry("TargetValue","sdk-device-id-123").containsEntry("DeviceType","ANDROID")
        .containsEntry("PushType","MESSAGE")
        .containsEntry("JobKey",delivery).containsEntry("StoreOffline","false").containsEntry("AndroidRemind","false");
    assertThat(params).doesNotContainKeys("AndroidOpenType","AndroidNotificationChannel","AndroidExtParameters");
    var ext=json.readTree(params.get("Body"));
    assertThat(ext.size()).isEqualTo(4);
    assertThat(ext.path("eventId").asText()).isEqualTo(event);
    assertThat(ext.path("deliveryId").asText()).isEqualTo(delivery);
    assertThat(ext.path("installationId").asText()).isEqualTo("85111111-1111-4111-8111-111111111111");
    assertThat(ext.path("deepLink").asText()).isEqualTo("aimanager://notifications/"+event);
    String signature=params.remove("Signature");
    String canonical=params.entrySet().stream().map(e->encode(e.getKey())+"="+encode(e.getValue())).collect(java.util.stream.Collectors.joining("&"));
    Mac mac=Mac.getInstance("HmacSHA1"); mac.init(new SecretKeySpec("test-access-secret&".getBytes(StandardCharsets.UTF_8),"HmacSHA1"));
    String independentlySigned=Base64.getEncoder().encodeToString(mac.doFinal(("POST&%2F&"+encode(canonical)).getBytes(StandardCharsets.UTF_8)));
    assertThat(signature).isEqualTo(independentlySigned);
    assertThat(body(request)).doesNotContain("test-access-secret");
  }
  @Test void rejectsProviderErrorAndMalformedSuccessWithoutCallingItDelivery() throws Exception {
    response(503,"{\"Code\":\"ServiceUnavailable\",\"Message\":\"sensitive vendor diagnostics\"}");
    assertThatThrownBy(()->gateway.send(command())).isInstanceOf(FamilyPushGateway.Failure.class).hasMessage("PROVIDER_UNAVAILABLE");
    response(200,"{\"RequestId\":\"fixture-request\"}");
    assertThatThrownBy(()->gateway.send(command())).isInstanceOf(FamilyPushGateway.Failure.class).hasMessage("PROVIDER_RESPONSE_INVALID");
    response(400,"{\"Code\":\"InvalidDeviceId\"}");
    assertThatThrownBy(()->gateway.send(command())).isInstanceOf(FamilyPushGateway.Failure.class).hasMessage("PROVIDER_REJECTED");
  }
  @Test void credentialsAndWorkerRemainUnavailableByDefault() {
    assertThat(FamilyPushAliyunGateway.configured(new MockEnvironment(),json,Clock.systemUTC())).isNull();
    assertThat(FamilyPushAliyunGateway.configured(new MockEnvironment().withProperty("manager.family.push.aliyun.enabled","true")
        .withProperty("manager.family.push.aliyun.credentials-file","missing-fixture.json"),json,Clock.systemUTC())).isNull();
  }
  @SuppressWarnings("unchecked") void response(int status,String raw) throws Exception {
    HttpResponse<InputStream> response=mock(HttpResponse.class);
    when(response.statusCode()).thenReturn(status); when(response.body()).thenAnswer(inv->new ByteArrayInputStream(raw.getBytes(StandardCharsets.UTF_8)));
    when(http.send(any(HttpRequest.class),any(HttpResponse.BodyHandler.class))).thenAnswer(inv->{sent.set(inv.getArgument(0));return response;});
  }
  FamilyPushGateway.Command command() { return new FamilyPushGateway.Command(delivery,"sdk-device-id-123",event,"85111111-1111-4111-8111-111111111111","家庭提醒","打开应用查看更新。","aimanager://notifications/"+event); }
  static String encode(String value) { return URLEncoder.encode(value,StandardCharsets.UTF_8).replace("+","%20").replace("*","%2A").replace("%7E","~"); }
  static SortedMap<String,String> parse(String raw) {
    var result=new TreeMap<String,String>();
    for(String parameter:raw.split("&")){var pair=parameter.split("=",2);result.put(URLDecoder.decode(pair[0],StandardCharsets.UTF_8),URLDecoder.decode(pair[1],StandardCharsets.UTF_8));}
    return result;
  }
  static String body(HttpRequest request) {
    var stream=new ByteArrayOutputStream();
    request.bodyPublisher().orElseThrow().subscribe(new Flow.Subscriber<ByteBuffer>() {
      public void onSubscribe(Flow.Subscription value){value.request(Long.MAX_VALUE);}
      public void onNext(ByteBuffer bytes){while(bytes.hasRemaining())stream.write(bytes.get());}
      public void onError(Throwable error){throw new AssertionError(error);} public void onComplete(){}
    });
    return stream.toString(StandardCharsets.UTF_8);
  }
}
