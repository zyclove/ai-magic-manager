package com.aimanager.parent;
import java.security.SecureRandom;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
public final class ConsumerAuthState {
  private final SecureRandom random=new SecureRandom();
  private String expected;
  private long started;
  public synchronized String begin(long now){
    byte[] bytes=new byte[32];random.nextBytes(bytes);StringBuilder state=new StringBuilder(64);
    for(byte value:bytes)state.append(String.format(java.util.Locale.ROOT,"%02x",value&255));
    expected=state.toString();started=now;return expected;
  }
  public synchronized boolean accept(String state,long now){
    if(expected==null||state==null)return false;
    if(now<started||now-started>=120000){cancel();return false;}
    if(!MessageDigest.isEqual(expected.getBytes(StandardCharsets.US_ASCII),state.getBytes(StandardCharsets.US_ASCII)))return false;
    cancel();return true;
  }
  public synchronized void cancel(){expected=null;started=0;}
}
