package com.aimanager.notification.internal;

import org.springframework.core.env.Environment;
import org.springframework.http.HttpStatus;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}")
class FamilyPushController {
  private final FamilyPushService service;
  private final FamilyPushGateway gateway;
  private final Environment environment;
  FamilyPushController(FamilyPushService service,FamilyPushGateway gateway,Environment environment) {
    this.service=service; this.gateway=gateway; this.environment=environment;
  }
  @PutMapping("/push-installations/{installationId}")
  ResponseEntity<FamilyPushService.Installation> register(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,
      @PathVariable String installationId,@RequestBody FamilyPushService.Registration value) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.register(tenantId,actor.getSubject(),installationId,value));
  }
  @DeleteMapping("/push-installations/{installationId}")
  @ResponseStatus(HttpStatus.NO_CONTENT)
  void revoke(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,@PathVariable String installationId) {
    service.revoke(tenantId,actor.getSubject(),installationId);
  }
  @GetMapping("/notification-preferences")
  ResponseEntity<FamilyPushService.Preferences> preferences(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.preferences(tenantId,actor.getSubject()));
  }
  @PutMapping("/notification-preferences")
  ResponseEntity<FamilyPushService.Preferences> preferences(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,
      @RequestBody FamilyPushService.Preferences value) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.preferences(tenantId,actor.getSubject(),value));
  }
  @GetMapping("/push-readiness")
  ResponseEntity<Readiness> readiness(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId) {
    service.preferences(tenantId,actor.getSubject());
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(new Readiness("ALIYUN","ANDROID",gateway.available(),
        environment.getProperty("manager.family.push.worker.enabled",Boolean.class,false),false,false));
  }
  record Readiness(String provider,String platform,boolean providerConfigured,boolean workerEnabled,
      boolean nativeIntegrationVerified,boolean deliveryVerified) {}
}
