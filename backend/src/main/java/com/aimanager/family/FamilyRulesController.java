package com.aimanager.family;
import com.aimanager.shared.ResourceVersions;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;
@RestController
@RequestMapping("/api/v1/tenants/{tenant}/subjects/{subject}/family-rules")
class FamilyRulesController {
  private final FamilyRulesService rules;
  FamilyRulesController(FamilyRulesService rules){this.rules=rules;}
  @GetMapping ResponseEntity<FamilyRulesService.View> read(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@PathVariable String subject){
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(rules.read(tenant,actor.getSubject(),subject));
  }
  @PutMapping ResponseEntity<FamilyRulesService.View> save(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@PathVariable String subject,
      @RequestHeader("If-Match") String version,@RequestHeader("Idempotency-Key") String key,@RequestBody FamilyRuleSpec spec){
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(rules.save(tenant,actor.getSubject(),subject,spec,ResourceVersions.require(version),key));
  }
}
