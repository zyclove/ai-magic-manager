package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

class ConsumerAccountSpiPackagingTest {
  @Test void restSpiRegistrationAndProviderMarkerArePackaged()throws Exception{
    var loader=getClass().getClassLoader();
    try(var beans=loader.getResourceAsStream("META-INF/beans.xml")){assertNotNull(beans);assertEquals(0,beans.readAllBytes().length);}
    try(var service=loader.getResourceAsStream("META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory")){
      assertNotNull(service);String implementation=new String(service.readAllBytes(),StandardCharsets.UTF_8).strip();
      assertInstanceOf(org.keycloak.services.resource.RealmResourceProviderFactory.class,Class.forName(implementation).getConstructor().newInstance());
    }
    assertNotNull(ConsumerAccountResource.class.getAnnotation(jakarta.ws.rs.ext.Provider.class));
  }
}
