package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** Platform configuration remains outside family erasure; new schema still needs exact review. */
class IdentityProviderCatalogTest {
  @Test void allNinePlatformStoresHaveExplicitGlobalClassifications()throws Exception{
    var expected=Map.of("identity_provider_heads","OPERATIONAL_METADATA","identity_provider_versions","SHARED_CONFIGURATION",
        "identity_provider_release_preparations","OPERATIONAL_METADATA","identity_provider_acceptance_runs","OPERATIONAL_METADATA","identity_provider_audit_events","AUDIT_RETENTION",
        "identity_provider_runtime_heads","OPERATIONAL_METADATA","identity_provider_release_operations","OPERATIONAL_METADATA","identity_provider_runtime_checks","OPERATIONAL_METADATA","identity_provider_executor_nonces","OPERATIONAL_METADATA");
    try(var input=new ClassPathResource("retention/subject-data-stores.json").getInputStream()){
      var document=new ObjectMapper().readTree(input);int count=0;
      for(var store:document.path("stores")){
        String table=store.path("table").asText();if(!expected.containsKey(table))continue;count++;
        assertEquals("identityproviders",store.path("domain").asText());assertEquals(expected.get(table),store.path("category").asText());
        for(var column:store.path("columns"))assertFalse(Set.of("tenant_id","subject_id","device_id","registration_id","phone_number").contains(column.asText()));
      }
      assertEquals(9,count);
    }
  }
  @Test void fullPhysicalSchemaPassesButUnknownTableAndUnknownProviderColumnStillBlock(){
    var source=new DriverManagerDataSource("jdbc:h2:mem:provider-catalog-"+UUID.randomUUID()+";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE","sa","");
    Flyway.configure().dataSource(source).locations("classpath:db/migration","classpath:db/vendor/h2").load().migrate();
    var db=new JdbcTemplate(source);var catalog=new SubjectDataCatalog(db,new ObjectMapper());assertNotNull(catalog.requireCurrentSchema());
    db.execute("CREATE TABLE unreviewed_provider_probe(id INT)");
    try{assertEquals("ERASURE_SCHEMA_REVIEW_REQUIRED",assertThrows(DomainException.class,catalog::requireCurrentSchema).errorCode());}
    finally{db.execute("DROP TABLE unreviewed_provider_probe");}
    db.execute("ALTER TABLE identity_provider_versions ADD COLUMN unreviewed_provider_payload TEXT");
    try{assertEquals("ERASURE_SCHEMA_REVIEW_REQUIRED",assertThrows(DomainException.class,catalog::requireCurrentSchema).errorCode());}
    finally{db.execute("ALTER TABLE identity_provider_versions DROP COLUMN unreviewed_provider_payload");}
    assertNotNull(catalog.requireCurrentSchema());
  }
}
