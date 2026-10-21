package com.aimanager.identity;

import org.junit.jupiter.api.Test;
import org.keycloak.models.SingleUseObjectProvider;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

class PhoneOtpTest {
    static final String SECRET = "test-hmac-key-at-least-32-bytes-long";
    static final Instant NOW = Instant.parse("2026-10-15T05:00:00Z");
    static final class Store implements SingleUseObjectProvider {
        final ConcurrentHashMap<String, Map<String,String>> entries = new ConcurrentHashMap<>();
        public void put(String key,long seconds,Map<String,String> notes){entries.put(key,Map.copyOf(notes));}
        public Map<String,String> get(String key){return entries.get(key);}
        public Map<String,String> remove(String key){return entries.remove(key);}
        public boolean replace(String key,Map<String,String> notes){return entries.replace(key,Map.copyOf(notes))!=null;}
        public boolean putIfAbsent(String key,long seconds){return entries.putIfAbsent(key,Map.of())==null;}
        public boolean contains(String key){return entries.containsKey(key);}
        public void close(){}
    }
    @Test void canonicalizesMainlandNumbersAndRejectsOtherCountriesAndMalformedInput(){
        assertEquals("+8613800138000",PhoneOtp.canonicalPhone("13800138000"));
        assertEquals("+8613800138000",PhoneOtp.canonicalPhone("+8613800138000"));
        for(String bad: new String[]{"+85213800138000","12800138000","13800138000,13900139000","13800138000\n",""})
            assertThrows(IllegalArgumentException.class,()->PhoneOtp.canonicalPhone(bad));
    }
    @Test void codeIsSecretBoundToSessionAndPhoneExpiresAndConsumesOnce() throws Exception {
        Store store=new Store(); String[] sent={null};
        PhoneOtp otp=new PhoneOtp(store,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(phone,code)->sent[0]=code);
        String challenge=otp.send("realm/session-a","13800138000","203.0.113.1");
        assertTrue(sent[0].matches("[0-9]{6}"));
        assertTrue(store.get("consumer:otp:"+challenge).get("code").matches("[a-f0-9]{64}"));
        assertNotEquals(sent[0],store.get("consumer:otp:"+challenge).get("code"));
        assertFalse(otp.verify(challenge,"realm/session-b","13800138000",sent[0]));
        assertFalse(otp.verify(challenge,"realm/session-a","13900139000",sent[0]));
        assertTrue(otp.verify(challenge,"realm/session-a","13800138000",sent[0]));
        assertFalse(otp.verify(challenge,"realm/session-a","13800138000",sent[0]));
        String expired=otp.send("realm/session-a","13900139000","203.0.113.2");
        PhoneOtp later=new PhoneOtp(store,SECRET,Clock.fixed(NOW.plusSeconds(300),ZoneOffset.UTC),(p,c)->{});
        assertFalse(later.verify(expired,"realm/session-a","13900139000",sent[0]));
    }
    @Test void fifthFailedAttemptPermanentlyExhaustsChallenge() throws Exception {
        Store store=new Store();String[] sent={null};
        PhoneOtp otp=new PhoneOtp(store,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->sent[0]=c);
        String challenge=otp.send("realm/session","13800138000","203.0.113.1");
        String wrong=sent[0].equals("000000")?"111111":"000000";
        for(int i=0;i<5;i++) assertFalse(otp.verify(challenge,"realm/session","13800138000",wrong));
        assertFalse(otp.verify(challenge,"realm/session","13800138000",sent[0]));
    }
    @Test void throttlesPhoneAcrossSessionsAndDoesNotCreateChallengeWhenProviderFails() throws Exception {
        Store store=new Store(); PhoneOtp otp=new PhoneOtp(store,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->{});
        otp.send("realm/a","13800138000","203.0.113.1");
        assertThrows(PhoneOtp.RateLimited.class,()->otp.send("realm/b","13800138000","203.0.113.2"));
        PhoneOtp failed=new PhoneOtp(new Store(),SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->{throw new java.io.IOException("provider down");});
        assertThrows(java.io.IOException.class,()->failed.send("realm/a","13900139000","203.0.113.2"));
    }
    @Test void concurrentVerificationOnlyAuthenticatesOneRequest() throws Exception {
        Store store=new Store();String[] sent={null};
        PhoneOtp otp=new PhoneOtp(store,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->sent[0]=c);
        String challenge=otp.send("realm/session","13800138000","203.0.113.1");
        ExecutorService pool=Executors.newFixedThreadPool(8);
        try { var tasks=java.util.stream.IntStream.range(0,30).<Callable<Boolean>>mapToObj(i->()->otp.verify(challenge,"realm/session","13800138000",sent[0])).toList();
            int success=0; for(var f:pool.invokeAll(tasks))if(f.get())success++;assertEquals(1,success);
        } finally {pool.shutdownNow();}
    }
    @Test void dailyPhoneAndHourlyIpBudgetsStopFurtherSmsDispatch() throws Exception {
        Store store=new Store();int[] sent={0};
        PhoneOtp otp=new PhoneOtp(store,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->sent[0]++);
        for(int i=0;i<10;i++){
            store.entries.keySet().removeIf(key->key.startsWith("consumer:cooldown:"));
            otp.send("realm/phone-"+i,"13800138000","203.0.113.1");
        }
        store.entries.keySet().removeIf(key->key.startsWith("consumer:cooldown:"));
        assertThrows(PhoneOtp.RateLimited.class,()->otp.send("realm/phone-11","13800138000","203.0.113.2"));
        assertEquals(10,sent[0]);
        Store ipStore=new Store();int[] ipSent={0};
        PhoneOtp ipOtp=new PhoneOtp(ipStore,SECRET,Clock.fixed(NOW,ZoneOffset.UTC),(p,c)->ipSent[0]++);
        for(int i=0;i<50;i++)ipOtp.send("realm/ip-"+i,Long.toString(13000000000L+i),"203.0.113.1");
        assertThrows(PhoneOtp.RateLimited.class,()->ipOtp.send("realm/ip-51","13000000050","203.0.113.1"));
        assertEquals(50,ipSent[0]);
    }
}
