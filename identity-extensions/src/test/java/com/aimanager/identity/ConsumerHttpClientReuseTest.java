package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Clock;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Synthetic transports only; these regressions must run against the unchanged baseline first. */
class ConsumerHttpClientReuseTest {
  @Test void factoryReusesOneClientAcrossDistinctAuthenticatorInstances() {
    var fixture=new ConsumerAccountFlowTest.Fixture();
    var runtime=new ConsumerProviderRuntime(fixture.config,null,Clock.systemUTC());
    var client=mock(HttpClient.class);
    var builder=mock(HttpClient.Builder.class,RETURNS_SELF);
    when(builder.build()).thenReturn(client);
    try(var runtimes=mockStatic(ConsumerProviderRuntime.class);
        var clients=mockStatic(HttpClient.class)) {
      runtimes.when(ConsumerProviderRuntime::current).thenReturn(runtime);
      clients.when(HttpClient::newBuilder).thenReturn(builder);
      var factory=new ConsumerAuthenticatorFactory();
      try {
        factory.init(null);
        var first=factory.create(null);
        var second=factory.create(null);
        assertNotSame(first,second,"Authentication request state must remain separate");
        verify(builder,times(1)).build();
      } finally {
        factory.close();
      }
    }
  }

  @Test void injectedProvidersDoNotCreateClientsDuringPhoneChangeAndOtpVerification() {
    var client=mock(HttpClient.class);
    var builder=mock(HttpClient.Builder.class,RETURNS_SELF);
    when(builder.build()).thenReturn(client);
    try(var clients=mockStatic(HttpClient.class)) {
      clients.when(HttpClient::newBuilder).thenReturn(builder);
      var fixture=new ConsumerAccountFlowTest.Fixture();
      var user=fixture.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);
      fixture.start("CHANGE_PHONE",ConsumerAccountFlowTest.ACTOR,"1",null);
      fixture.send(ConsumerAccountFlowTest.OLD);
      fixture.verifyLast();
      fixture.send(ConsumerAccountFlowTest.NEW);
      fixture.verifyLast();
      assertEquals(ConsumerAccountFlowTest.NEW,user.getFirstAttribute("consumer_phone_number"));
      assertEquals(1,fixture.successes);
      clients.verify(HttpClient::newBuilder,never());
      verifyNoInteractions(client);
    }
  }

  @Test void factoryUsesTheSameClientForWechatSmsAndOtpVerification() throws Exception {
    var fixture=new ConsumerAccountFlowTest.Fixture();
    var runtime=new ConsumerProviderRuntime(fixture.config,null,Clock.systemUTC());
    var client=mock(HttpClient.class);
    var builder=mock(HttpClient.Builder.class,RETURNS_SELF);
    when(builder.build()).thenReturn(client);
    when(client.sendAsync(any(HttpRequest.class),org.mockito.ArgumentMatchers.<HttpResponse.BodyHandler<byte[]>>any()))
        .thenAnswer(invocation->{
          HttpRequest request=invocation.getArgument(0);
          return java.util.concurrent.CompletableFuture.completedFuture(response(request.uri().getHost().equals("api.weixin.qq.com")
              ?"{\"access_token\":\"synthetic-token\",\"openid\":\"wechat-a\"}"
              :"{\"Code\":\"OK\"}"));
        });
    try(var runtimes=mockStatic(ConsumerProviderRuntime.class);
        var clients=mockStatic(HttpClient.class)) {
      runtimes.when(ConsumerProviderRuntime::current).thenReturn(runtime);
      clients.when(HttpClient::newBuilder).thenReturn(builder);
      var factory=new ConsumerAuthenticatorFactory();
      try {
        factory.init(null);
        fixture.authenticator=(ConsumerAuthenticator)factory.create(fixture.session);
        var user=fixture.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);
        fixture.links.put("wechat-a",user);
        fixture.start("RECOVER_PHONE",null,null,"code-a");
        fixture.send(ConsumerAccountFlowTest.NEW);
        fixture.verify("not-an-otp");
        assertEquals(0,fixture.successes);
        assertEquals(ConsumerAccountFlowTest.OLD,user.getFirstAttribute("consumer_phone_number"));
        verify(client,times(2)).sendAsync(any(HttpRequest.class),org.mockito.ArgumentMatchers.<HttpResponse.BodyHandler<byte[]>>any());
        verify(builder,times(1)).build();
      } finally {
        factory.close();
      }
    }
  }

  @Test void disabledOrIncompleteProviderConfigurationDoesNotFailFactoryInitialization() {
    for(Map<String,String> configuration:java.util.List.of(Map.<String,String>of(),
        Map.of("CONSUMER_PHONE_ENABLED","true","CONSUMER_OTP_HMAC_KEY",PhoneOtpTest.SECRET))) {
      var runtime=new ConsumerProviderRuntime(configuration,null,Clock.systemUTC());
      var fixture=new ConsumerAccountFlowTest.Fixture();
      var client=mock(HttpClient.class);
      var builder=mock(HttpClient.Builder.class,RETURNS_SELF);
      when(builder.build()).thenReturn(client);
      try(var runtimes=mockStatic(ConsumerProviderRuntime.class);
          var clients=mockStatic(HttpClient.class)) {
        runtimes.when(ConsumerProviderRuntime::current).thenReturn(runtime);
        clients.when(HttpClient::newBuilder).thenReturn(builder);
        var factory=new ConsumerAuthenticatorFactory();
        try {
          assertDoesNotThrow(()->factory.init(null));
          assertDoesNotThrow(()->factory.create(null).authenticate(fixture.context));
          assertEquals(0,fixture.successes);
          verifyNoInteractions(client);
        } finally {
          factory.close();
        }
      }
    }
  }

  @SuppressWarnings("unchecked")
  private static HttpResponse<byte[]> response(String body) {
    HttpResponse<byte[]> response=mock(HttpResponse.class);
    when(response.statusCode()).thenReturn(200);
    when(response.body()).thenReturn(body.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    return response;
  }
}
