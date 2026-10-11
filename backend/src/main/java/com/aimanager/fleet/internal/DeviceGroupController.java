package com.aimanager.fleet.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Institution inventory grouping; these routes do not publish or enforce policy. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/device-groups")
class DeviceGroupController {
  private static final String UUID =
      "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  private final DeviceGroupService groups;

  DeviceGroupController(DeviceGroupService groups) {
    this.groups = groups;
  }

  @GetMapping
  ItemPage<DeviceGroupService.Group> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor,
      @RequestParam(defaultValue = "false") boolean includeArchived) {
    return groups.list(tenantId, actor.getSubject(), limit, cursor, includeArchived);
  }

  @PostMapping
  ResponseEntity<DeviceGroupService.Group> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Name body,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(groups.create(tenantId, actor, body.name(), key), HttpStatus.CREATED);
  }

  @GetMapping("/{groupId}")
  ResponseEntity<DeviceGroupService.Group> get(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId) {
    return response(groups.get(tenantId, actor.getSubject(), groupId), HttpStatus.OK);
  }

  @PatchMapping("/{groupId}")
  ResponseEntity<DeviceGroupService.Group> rename(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @Valid @RequestBody Name body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(groups.rename(tenantId, actor, groupId, body.name(), etag, key), HttpStatus.OK);
  }

  @PostMapping("/{groupId}/archive")
  ResponseEntity<DeviceGroupService.Group> archive(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(groups.archive(tenantId, actor, groupId, etag, key), HttpStatus.OK);
  }

  @GetMapping("/{groupId}/devices")
  ItemPage<DeviceGroupService.Member> devices(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return groups.members(tenantId, actor.getSubject(), groupId, limit, cursor);
  }

  @PostMapping("/{groupId}/devices")
  ResponseEntity<DeviceGroupService.Group> add(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @Valid @RequestBody Device body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(groups.member(tenantId, actor, groupId, body.deviceId(),
        body.registrationId(), true, etag, key), HttpStatus.OK);
  }

  /** One transaction and one group revision for an explicit list of current registrations. */
  @PostMapping("/{groupId}/devices/batches")
  ResponseEntity<DeviceGroupService.Group> addBatch(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @Valid @RequestBody Batch body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    var targets = body.devices().stream()
        .map(d -> new DeviceGroupService.DeviceTarget(d.deviceId(), d.registrationId()))
        .toList();
    return response(groups.addMembers(tenantId, actor, groupId, targets, etag, key), HttpStatus.OK);
  }

  @DeleteMapping("/{groupId}/devices/{deviceId}")
  ResponseEntity<DeviceGroupService.Group> remove(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String groupId,
      @PathVariable String deviceId,
      @RequestParam String registrationId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(groups.member(tenantId, actor, groupId, deviceId,
        registrationId, false, etag, key), HttpStatus.OK);
  }

  private ResponseEntity<DeviceGroupService.Group> response(
      DeviceGroupService.Group group, HttpStatus status) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(group.version())).body(group);
  }

  record Name(@NotBlank @Size(max = 100) String name) {}

  record Device(
      @NotNull @Pattern(regexp = UUID) String deviceId,
      @NotNull @Pattern(regexp = UUID) String registrationId) {}

  record Batch(@NotNull @Size(min = 1, max = 50) List<@NotNull @Valid Device> devices) {}
}
