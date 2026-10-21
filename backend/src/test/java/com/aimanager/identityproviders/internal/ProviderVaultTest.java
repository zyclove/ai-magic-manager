package com.aimanager.identityproviders.internal;

import static org.junit.jupiter.api.Assertions.*;
import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.DirectEncrypter;
import com.nimbusds.jose.jwk.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ProviderVaultTest {
  @TempDir Path directory;
  OctetSequenceKey key(String id){byte[] value=new byte[32];new java.security.SecureRandom().nextBytes(value);return new OctetSequenceKey.Builder(value).keyID(id).keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build();}
  Path ring(String name,JWK...keys)throws Exception{Path file=directory.resolve(name);Files.writeString(file,new JWKSet(Arrays.asList(keys)).toString(false));return file;}
  @Test void bindsEnvironmentVersionAndPurposeAndNeverContainsPlaintext()throws Exception{
    var vault=new ProviderVault(ring("key.json",key("current")).toString(),"");byte[] plain="PRIVATE_SECRET_FIXTURE".getBytes(StandardCharsets.UTF_8);
    String sealed=vault.seal(ProviderConfigurationService.VAULT,"family-pilot","version",plain);
    assertFalse(sealed.contains("PRIVATE_SECRET_FIXTURE"));assertArrayEquals(plain,vault.open(ProviderConfigurationService.VAULT,"family-pilot","version",sealed));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.VAULT,"other","version",sealed));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.VAULT,"family-pilot","other",sealed));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.REQUEST,"family-pilot","version",sealed));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.RELEASE,"family-pilot","version",sealed));
  }
  @Test void releaseHeaderMatchesTheIndependentDeploymentToolContract()throws Exception{
    var vault=new ProviderVault(ring("key.json",key("current")).toString(),"");var jwe=JWEObject.parse(vault.seal(ProviderConfigurationService.RELEASE,"env","id",new byte[0]));
    assertEquals("family-identity-provider-release+jwe",jwe.getHeader().getType().toString());
    assertEquals("application/json",jwe.getHeader().getContentType());assertEquals(JWEAlgorithm.DIR,jwe.getHeader().getAlgorithm());
    assertEquals(EncryptionMethod.A256GCM,jwe.getHeader().getEncryptionMethod());assertNull(jwe.getHeader().getCompressionAlgorithm());
    assertEquals("env",jwe.getHeader().getCustomParam("environmentId"));assertEquals("id",jwe.getHeader().getCustomParam("versionId"));
  }
  @Test void modifiedTagUnknownHeaderAndOversizeAreRejected()throws Exception{
    var key=key("current");var vault=new ProviderVault(ring("key.json",key).toString(),"");String sealed=vault.seal(ProviderConfigurationService.VAULT,"env","id",new byte[0]);
    String[] parts=sealed.split("\\.",-1);parts[4]=(parts[4].startsWith("A")?"B":"A")+parts[4].substring(1);
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.VAULT,"env","id",String.join(".",parts)));
    var h=new JWEHeader.Builder(JWEAlgorithm.DIR,EncryptionMethod.A256GCM).keyID("current").type(new JOSEObjectType("family-identity-provider-vault+jwe"))
        .contentType("application/json").customParam("purpose",ProviderConfigurationService.VAULT).customParam("environmentId","env").customParam("versionId","id").customParam("unexpected","ignored?").build();
    var extra=new JWEObject(h,new Payload(new byte[0]));extra.encrypt(new DirectEncrypter(key));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.VAULT,"env","id",extra.serialize()));
    assertThrows(DomainException.class,()->vault.seal(ProviderConfigurationService.VAULT,"env","id",new byte[65537]));
    assertThrows(DomainException.class,()->vault.open(ProviderConfigurationService.VAULT,"env","id","a".repeat(131073)));
  }
  @Test void rotationRetainsOldDecryptKeysAndRequiresAnExplicitActiveKey()throws Exception{
    var old=key("old");var current=key("current");Path first=ring("first.json",old),second=ring("second.json",old,current);
    String sealed=new ProviderVault(first.toString(),"").seal(ProviderConfigurationService.VAULT,"env","id",new byte[]{7});
    var rotated=new ProviderVault(second.toString(),"current");assertArrayEquals(new byte[]{7},rotated.open(ProviderConfigurationService.VAULT,"env","id",sealed));
    assertEquals("current",JWEObject.parse(rotated.seal(ProviderConfigurationService.VAULT,"env","id",new byte[0])).getHeader().getKeyID());
    assertFalse(new ProviderVault(second.toString(),"").available());
  }
  @Test void missingMalformedDuplicateAndWrongUseKeysDisableTheOptionalVault()throws Exception{
    assertFalse(new ProviderVault("","").available());assertFalse(new ProviderVault(directory.resolve("missing").toString(),"").available());
    var key=key("same");assertFalse(new ProviderVault(ring("duplicate.json",key,key).toString(),"").available());
    var signing=new OctetSequenceKey.Builder(new byte[32]).keyID("signing").keyUse(KeyUse.SIGNATURE).algorithm(JWEAlgorithm.DIR).build();
    assertFalse(new ProviderVault(ring("signing.json",signing).toString(),"").available());
    Path duplicateJson=directory.resolve("duplicate-json.json");Files.writeString(duplicateJson,"{\"keys\":[],\"keys\":["+key.toJSONString()+"]}");
    assertFalse(new ProviderVault(duplicateJson.toString(),"").available());
    assertEquals("IDENTITY_PROVIDER_VAULT_UNAVAILABLE",assertThrows(DomainException.class,()->new ProviderVault("","").requireAvailable()).errorCode());
  }
}
