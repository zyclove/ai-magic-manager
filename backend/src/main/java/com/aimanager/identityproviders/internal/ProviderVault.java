package com.aimanager.identityproviders.internal;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** A dedicated authenticated key ring. Configuration errors disable this optional vault only. */
@Component
final class ProviderVault {
  private static final ObjectMapper STRICT=new ObjectMapper().enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
      .disable(JsonParser.Feature.INCLUDE_SOURCE_IN_LOCATION);
  private static final Set<String> HEADERS=Set.of("alg","enc","typ","cty","kid","purpose","environmentId","versionId");
  private final Map<String,byte[]> keys;
  private final String active;
  ProviderVault(@Value("${manager.identity-providers.key-file:}") String file,
      @Value("${manager.identity-providers.active-key-id:}") String activeId){
    Map<String,byte[]> ring=new HashMap<>();String selected=null;
    try{
      if(file.isBlank())throw new IllegalArgumentException();Path path=Path.of(file);noLinks(path);
      if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>65536)throw new IllegalArgumentException();
      String contents=Files.readString(path);STRICT.readTree(contents);
      var jwks=JWKSet.parse(contents);
      for(var key:jwks.getKeys()){
        if(!(key instanceof OctetSequenceKey oct)||oct.size()!=256||key.getKeyID()==null
            ||!key.getKeyID().matches("[A-Za-z0-9._-]{1,64}")||!KeyUse.ENCRYPTION.equals(key.getKeyUse())
            ||!JWEAlgorithm.DIR.equals(key.getAlgorithm())||ring.putIfAbsent(key.getKeyID(),oct.toByteArray())!=null)throw new IllegalArgumentException();
      }
      if(ring.isEmpty()||ring.size()>8)throw new IllegalArgumentException();
      selected=activeId.isBlank()&&ring.size()==1?ring.keySet().iterator().next():activeId;
      if(!ring.containsKey(selected))throw new IllegalArgumentException();
    }catch(Exception unavailable){ring.clear();selected=null;}
    keys=Map.copyOf(ring);active=selected;
  }
  boolean available(){return active!=null;}
  void requireAvailable(){if(!available())throw unavailable();}
  String seal(String purpose,String environment,String version,byte[] plaintext){
    requireAvailable();
    try{
      if(plaintext==null||plaintext.length>65536)throw new IllegalArgumentException();
      var h=new JWEHeader.Builder(JWEAlgorithm.DIR,EncryptionMethod.A256GCM).keyID(active)
          .type(new JOSEObjectType(type(purpose))).contentType("application/json")
          .customParam("purpose",purpose).customParam("environmentId",environment).customParam("versionId",version).build();
      var jwe=new JWEObject(h,new Payload(plaintext));jwe.encrypt(new DirectEncrypter(keys.get(active)));return jwe.serialize();
    }catch(Exception invalid){throw unavailable();}
  }
  byte[] open(String purpose,String environment,String version,String encrypted){
    requireAvailable();
    try{
      if(encrypted==null||encrypted.length()>131072)throw new IllegalArgumentException();
      var parts=encrypted.split("\\.",-1);if(parts.length!=5||parts[0].length()>8192||!parts[1].isEmpty())throw new IllegalArgumentException();
      STRICT.readTree(Base64.getUrlDecoder().decode(parts[0]));var jwe=JWEObject.parse(encrypted);var h=jwe.getHeader();
      if(!h.getIncludedParams().equals(HEADERS)||!JWEAlgorithm.DIR.equals(h.getAlgorithm())||!EncryptionMethod.A256GCM.equals(h.getEncryptionMethod())
          ||!new JOSEObjectType(type(purpose)).equals(h.getType())||!"application/json".equals(h.getContentType())
          ||!purpose.equals(h.getCustomParam("purpose"))||!environment.equals(h.getCustomParam("environmentId"))
          ||!version.equals(h.getCustomParam("versionId"))||!keys.containsKey(h.getKeyID()))throw new IllegalArgumentException();
      jwe.decrypt(new DirectDecrypter(keys.get(h.getKeyID())));byte[] plain=jwe.getPayload().toBytes();
      if(plain.length>65536)throw new IllegalArgumentException();return plain;
    }catch(Exception invalid){throw unavailable();}
  }
  static void noLinks(Path path)throws java.io.IOException{
    for(Path current=path.toAbsolutePath().normalize();current!=null;current=current.getParent()){
      if(Files.exists(current,LinkOption.NOFOLLOW_LINKS)){
        var attrs=Files.readAttributes(current,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
        if(attrs.isSymbolicLink()||attrs.isOther())throw new java.io.IOException("Unavailable private path");
      }
    }
  }
  private static String type(String purpose){return switch(purpose){
    case "family-identity-provider-release-v1"->"family-identity-provider-release+jwe";
    case "family-identity-provider-vault-v1","family-identity-provider-request-v1"->"family-identity-provider-vault+jwe";
    default->throw new IllegalArgumentException();};}
  private static DomainException unavailable(){return new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"IDENTITY_PROVIDER_VAULT_UNAVAILABLE");}
}
