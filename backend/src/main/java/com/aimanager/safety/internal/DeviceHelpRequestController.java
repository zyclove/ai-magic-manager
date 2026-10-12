package com.aimanager.safety.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.net.URI;
import java.util.UUID;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Device-authenticated, fixed routes; callers cannot choose a tenant or a different device. */
@RestController
@RequestMapping("/api/v1/device-api/help-requests")
@SecurityRequirement(name = "deviceBearer")
class DeviceHelpRequestController {
  private final HelpRequestService service;

  DeviceHelpRequestController(HelpRequestService service) {
    this.service = service;
  }

  @PostMapping
  ResponseEntity<HelpRequestService.HelpRequest> create(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,
      @Valid @RequestBody Create input) {
    var result = service.create(DeviceContext.from(principal), uuid(input.clientRequestId()),
        input.reasonCode());
    return ResponseEntity.status(result.created() ? HttpStatus.CREATED : HttpStatus.OK)
        .location(URI.create("/api/v1/device-api/help-requests/" + result.request().clientRequestId()))
        .cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .eTag(ResourceVersions.tag(result.request().version())).body(result.request());
  }

  /** Read after an uncertain POST; a 404 does not create a new request. */
  @GetMapping("/{clientRequestId}")
  ResponseEntity<HelpRequestService.HelpRequest> get(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,
      @PathVariable String clientRequestId) {
    var result = service.deviceGet(DeviceContext.from(principal), uuid(clientRequestId));
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .varyBy("Authorization").eTag(ResourceVersions.tag(result.version())).body(result);
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

  record Create(
      @NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
          String clientRequestId,
      @NotNull HelpRequestService.Reason reasonCode) {}
}
