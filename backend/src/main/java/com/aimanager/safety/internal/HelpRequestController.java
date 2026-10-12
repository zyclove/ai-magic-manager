package com.aimanager.safety.internal;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import java.util.UUID;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Adult attention inbox. Acknowledged means seen in this console, not resolved or dispatched. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/help-requests")
class HelpRequestController {
  private final HelpRequestService service;

  HelpRequestController(HelpRequestService service) {
    this.service = service;
  }

  @GetMapping
  ResponseEntity<ItemPage<HelpRequestService.HelpRequest>> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor,
      @RequestParam(required = false) HelpRequestService.State state) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .body(service.list(tenantId, actor.getSubject(), limit, cursor, state));
  }

  @GetMapping("/{id}")
  ResponseEntity<HelpRequestService.HelpRequest> get(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
      @PathVariable String id) {
    var result = service.get(tenantId, actor.getSubject(), uuid(id));
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .eTag(ResourceVersions.tag(result.version())).body(result);
  }

  @GetMapping("/open-count")
  ResponseEntity<HelpRequestService.OpenCount> openCount(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .body(service.openCount(tenantId, actor.getSubject()));
  }

  @PostMapping("/{id}/acknowledge")
  ResponseEntity<HelpRequestService.HelpRequest> acknowledge(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String etag) {
    var result = service.acknowledge(tenantId, actor.getSubject(), uuid(id), etag);
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .eTag(ResourceVersions.tag(result.version())).body(result);
  }

  private static UUID uuid(String raw) {
    try {
      var id = UUID.fromString(raw);
      if (!id.toString().equals(raw)) throw new IllegalArgumentException();
      return id;
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_HELP_REQUEST_ID");
    }
  }
}
