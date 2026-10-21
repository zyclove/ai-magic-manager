package com.aimanager.identity;

import org.junit.jupiter.api.Test;
import java.net.URI;
import java.time.Instant;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class AliyunSmsTest {
    @Test void signatureMatchesOfficialV3KnownAnswer(){
        Map<String,String> headers=new TreeMap<>(Map.of("host","ecs.cn-shanghai.aliyuncs.com","x-acs-action","RunInstances","x-acs-content-sha256","e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","x-acs-date","2023-10-26T10:22:32Z","x-acs-signature-nonce","3156853299f313e23d1673dc12e1703d","x-acs-version","2014-05-26"));
        String result=AliyunSms.authorization("YourAccessKeyId","YourAccessKeySecret","POST","/","ImageId=win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd&RegionId=cn-shanghai",headers,"");
        assertTrue(result.endsWith("Signature=06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0"));
    }
    @Test void sendsOnlyToPinnedChinaEndpointUsesOfficialQueryMetadataAndRejectsProviderFailure() throws Exception {
        List<AliyunSms.Request> requests=new ArrayList<>();
        AliyunSms sms=new AliyunSms("test-id","test-secret","approved-sign","SMS_123",null,
            request->{requests.add(request);return new AliyunSms.Response(200,"{\"Code\":\"OK\",\"Message\":\"OK\",\"BizId\":\"mock\",\"RequestId\":\"mock\"}");});
        sms.send("+8613800138000","123456");
        var request=requests.get(0);
        assertEquals("dysmsapi.aliyuncs.com",request.uri().getHost());
        assertEquals("/",request.uri().getPath());
        assertNotNull(request.uri().getRawQuery(),"SendSms fields must use the official query metadata");
        assertTrue(request.uri().getRawQuery().contains("PhoneNumbers=13800138000"));
        assertTrue(request.uri().getRawQuery().contains("TemplateParam=%7B%22code%22%3A%22123456%22%7D"));
        assertEquals("",request.body());
        assertTrue(request.headers().get("Authorization").startsWith("ACS3-HMAC-SHA256 Credential=test-id,"));
        assertThrows(java.io.IOException.class,()->new AliyunSms("id","secret","sign","SMS_123",null,r->new AliyunSms.Response(200,"{\"Code\":\"isv.BUSINESS_LIMIT_CONTROL\"}")).send("+8613800138000","123456"));
        assertThrows(IllegalArgumentException.class,()->new AliyunSms("","","","",null,r->{fail("must not send without config");return null;}));
    }
}
