package com.aimanager.family;
import java.util.Map;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;
@RestController
@RequestMapping("/api/v1/tenants/{tenant}/assistant")
class FamilyAssistantController {
  private final FamilyAssistantService service;
  FamilyAssistantController(FamilyAssistantService service){this.service=service;}
  @PostMapping("/suggestions") ResponseEntity<FamilyAssistantService.Suggestion> suggest(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,
      @RequestHeader(value="Idempotency-Key",required=false)String key,@RequestBody FamilyAssistantService.Request request){
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.generate(tenant,actor.getSubject(),request,key));
  }
  @PostMapping("/suggestions/{id}/drafts") ResponseEntity<Map<String,Object>> draft(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@PathVariable String id){
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.draft(tenant,actor.getSubject(),id));
  }
}
