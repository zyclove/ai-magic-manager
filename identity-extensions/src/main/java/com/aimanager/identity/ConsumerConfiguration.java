package com.aimanager.identity;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.nio.file.*;
import java.util.*;

/** 只读取固定配置与固定秘密项；文件错误时关闭消费者入口，不暴露文件路径或秘密内容。 */
final class ConsumerConfiguration {
  private static final Set<String> SECRET_KEYS=Set.of("CONSUMER_OTP_HMAC_KEY","ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET","ALIYUN_SMS_SECURITY_TOKEN","WECHAT_NATIVE_APP_SECRET");
  private static final Set<String> SETTINGS=Set.of("CONSUMER_PHONE_ENABLED","CONSUMER_WECHAT_ENABLED","CONSUMER_ACCOUNT_SECURITY_ENABLED","ALIYUN_SMS_SIGN_NAME","ALIYUN_SMS_TEMPLATE_CODE","WECHAT_NATIVE_APP_ID");
  private ConsumerConfiguration(){}
  static Map<String,String> load(Map<String,String> environment){
    Map<String,String> result=new HashMap<>();for(String key:SETTINGS)if(environment.get(key)!=null)result.put(key,environment.get(key));
    try{
      for(String key:SECRET_KEYS){String file=environment.get(key+"_FILE");String value=environment.get(key);if(file!=null&&!file.isBlank())value=readSecret(file);if(value!=null)result.put(key,value);}
      return Map.copyOf(result);
    }catch(IOException|IllegalArgumentException failure){
      for(String key:SECRET_KEYS)result.remove(key);result.put("CONSUMER_PHONE_ENABLED","false");result.put("CONSUMER_WECHAT_ENABLED","false");result.put("CONSUMER_ACCOUNT_SECURITY_ENABLED","false");return Map.copyOf(result);
    }
  }
  private static String readSecret(String file)throws IOException{
    byte[] bytes;try(var stream=Files.newInputStream(Path.of(file))){bytes=stream.readNBytes(8193);}
    if(bytes.length>8192)throw new IOException("Secret is unavailable");
    String value=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
    if(value.endsWith("\n"))value=value.substring(0,value.length()-1);
    if(value.endsWith("\r"))value=value.substring(0,value.length()-1);
    if(value.indexOf('\n')>=0||value.indexOf('\r')>=0||value.indexOf('\0')>=0)throw new IOException("Secret is unavailable");return value;
  }
  static boolean phoneAvailable(Map<String,String> config){
    if(!"true".equals(config.get("CONSUMER_PHONE_ENABLED")))return false;
    for(String key:Set.of("CONSUMER_OTP_HMAC_KEY","ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET","ALIYUN_SMS_SIGN_NAME","ALIYUN_SMS_TEMPLATE_CODE"))if(config.get(key)==null||config.get(key).isBlank())return false;
    return config.get("CONSUMER_OTP_HMAC_KEY").getBytes(StandardCharsets.UTF_8).length>=32;
  }
}
