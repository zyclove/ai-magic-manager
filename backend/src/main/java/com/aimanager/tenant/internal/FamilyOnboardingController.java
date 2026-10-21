package com.aimanager.tenant.internal;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.*;
import com.aimanager.tenant.Tenant;
import java.time.Clock;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

/** Consumer-only bootstrap: verified phone and recorded guardian declaration, never platform roles. */
@RestController
class FamilyOnboardingController {
  private final TenantService tenants;private final JdbcTemplate jdbc;private final Clock clock;
  FamilyOnboardingController(TenantService tenants,JdbcTemplate jdbc,Clock clock){this.tenants=tenants;this.jdbc=jdbc;this.clock=clock;}
  record Declaration(boolean adultGuardian,String declarationVersion){}
  @PostMapping("/api/v1/family-onboarding")
  @Transactional(timeout=10)
  ResponseEntity<Tenant> create(@AuthenticationPrincipal Jwt actor,@RequestHeader("Idempotency-Key") String key,@RequestBody Declaration declaration){
    String phone=actor.getClaimAsString("phone_number");
    if(!Boolean.TRUE.equals(actor.getClaim("phone_number_verified")) || phone==null || !phone.matches("\\+861[3-9][0-9]{9}"))
      throw new DomainException(HttpStatus.PRECONDITION_REQUIRED,"VERIFIED_PHONE_REQUIRED");
    if(!declaration.adultGuardian() || !"family-guardian-v1".equals(declaration.declarationVersion()))throw DomainException.invalid("GUARDIAN_DECLARATION_REQUIRED");
    if(key==null||key.isBlank())throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    var result=tenants.create(actor,"我的家庭",Tenant.Kind.FAMILY,"Asia/Shanghai","family-onboarding-"+key);
    jdbc.update("INSERT INTO family_guardian_declarations(actor_key,phone_hash,declaration_version,declared_at,tenant_id) VALUES(?,?,?,?,?) ON DUPLICATE KEY UPDATE declaration_version=VALUES(declaration_version)",
        ActorKeys.key(actor.getSubject()),SecretMaterial.hash(phone),declaration.declarationVersion(),clock.millis(),result.id());
    return ResponseEntity.status(HttpStatus.CREATED).cacheControl(CacheControl.noStore()).body(result);
  }
}
