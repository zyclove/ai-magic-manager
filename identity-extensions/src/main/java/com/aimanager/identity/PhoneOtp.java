package com.aimanager.identity;
import org.keycloak.models.SingleUseObjectProvider;
import java.time.Clock;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
public final class PhoneOtp {
  public interface Sender { void send(String phone,String code) throws IOException; }
  public static final class RateLimited extends RuntimeException {}
  private final SingleUseObjectProvider store;
  private final byte[] secret;
  private final Clock clock;
  private final Sender sender;
  private final SecureRandom random = new SecureRandom();
  public PhoneOtp(SingleUseObjectProvider store,String secret,Clock clock,Sender sender){
    if(secret==null || secret.getBytes(StandardCharsets.UTF_8).length<32)throw new IllegalArgumentException("OTP HMAC key requires 32 bytes");
    this.store=store;this.secret=secret.getBytes(StandardCharsets.UTF_8);this.clock=clock;this.sender=sender;
  }
  public static String canonicalPhone(String value){
    if(value==null || !value.matches("(?:\\+86)?1[3-9][0-9]{9}"))throw new IllegalArgumentException("Enter a mainland China mobile number");
    return value.startsWith("+86")?value:"+86"+value;
  }
  public String send(String binding,String phone,String ip)throws IOException{
    phone=canonicalPhone(phone);
    String phoneKey=digest("phone:"+phone),ipKey=digest("ip:"+ip);
    if(!store.putIfAbsent("consumer:cooldown:"+phoneKey,60))throw new RateLimited();
    reserve("consumer:daily:"+phoneKey+":"+Math.floorDiv(clock.instant().getEpochSecond(),86400),10,86400);
    reserve("consumer:hourly-ip:"+ipKey+":"+Math.floorDiv(clock.instant().getEpochSecond(),3600),50,3600);
    String challenge=UUID.randomUUID().toString();
    String code=String.format(java.util.Locale.ROOT,"%06d",random.nextInt(1_000_000));
    sender.send(phone,code);
    store.put("consumer:otp:"+challenge,300,Map.of("binding",digest(binding+":"+phone),"code",digest(challenge+":"+binding+":"+phone+":"+code),"expires",Long.toString(clock.instant().getEpochSecond()+300),"attempts","5"));
    return challenge;
  }
  private void reserve(String prefix,int limit,long ttl){
    for(int i=0;i<limit;i++)if(store.putIfAbsent(prefix+":"+i,ttl))return;
    throw new RateLimited();
  }
  public boolean verify(String challenge,String binding,String phone,String code){
    if(challenge==null || !challenge.matches("[a-f0-9-]{36}"))return false;
    try{phone=canonicalPhone(phone);}catch(IllegalArgumentException e){return false;}
    Map<String,String> notes=store.remove("consumer:otp:"+challenge);
    if(notes==null)return false;
    long remaining=Long.parseLong(notes.get("expires"))-clock.instant().getEpochSecond();
    if(remaining<=0)return false;
    boolean validBinding=equal(notes.get("binding"),digest(binding+":"+phone));
    boolean valid=validBinding && code!=null && code.matches("[0-9]{6}") && equal(notes.get("code"),digest(challenge+":"+binding+":"+phone+":"+code));
    if(valid)return true;
    int attempts=Integer.parseInt(notes.get("attempts"))-1;
    if(attempts>0){var retry=new java.util.HashMap<>(notes);retry.put("attempts",Integer.toString(attempts));store.put("consumer:otp:"+challenge,remaining,retry);}
    return false;
  }
  private static boolean equal(String first,String second){return MessageDigest.isEqual(first.getBytes(StandardCharsets.US_ASCII),second.getBytes(StandardCharsets.US_ASCII));}
  private String digest(String value){return hmac(secret,value);}
  static String hmac(byte[] secret,String value){
    try{Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(secret,"HmacSHA256"));return HexFormat.of().formatHex(mac.doFinal(value.getBytes(StandardCharsets.UTF_8)));}
    catch(java.security.GeneralSecurityException e){throw new IllegalStateException("HMAC unavailable",e);}
  }
}
