package com.aimanager.identityproviders.internal;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Independent host keys. No supplier secret, stable credential digest or OTP key is a proof key. */
final class ProviderRuntimeCrypto {
  private ProviderRuntimeCrypto() {}
  static byte[] key(String file)throws Exception{
    if(file==null||file.isBlank())throw new IllegalArgumentException();Path path=Path.of(file);
    ProviderVault.noLinks(path);if(!path.isAbsolute()||!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>46)throw new IllegalArgumentException();
    String value=Files.readString(path,StandardCharsets.US_ASCII);if(value.endsWith("\r\n"))value=value.substring(0,value.length()-2);else if(value.endsWith("\n"))value=value.substring(0,value.length()-1);
    if(!token(value))throw new IllegalArgumentException();return Base64.getUrlDecoder().decode(value);
  }
  static boolean token(String value){
    if(value==null||!value.matches("[A-Za-z0-9_-]{43}"))return false;
    try{byte[] bytes=Base64.getUrlDecoder().decode(value);return bytes.length==32&&Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).equals(value);}catch(IllegalArgumentException invalid){return false;}
  }
  static String mac(byte[] key,List<String> values){
    try{var output=new ByteArrayOutputStream();for(String value:values){byte[] bytes=value.getBytes(StandardCharsets.UTF_8);output.write(Integer.toString(bytes.length).getBytes(StandardCharsets.US_ASCII));output.write(':');output.write(bytes);}
      var mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(key,"HmacSHA256"));return Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal(output.toByteArray()));
    }catch(Exception unavailable){throw new IllegalStateException("Identity runtime proof unavailable");}
  }
  static boolean same(String left,String right){return token(left)&&token(right)&&MessageDigest.isEqual(Base64.getUrlDecoder().decode(left),Base64.getUrlDecoder().decode(right));}
}
