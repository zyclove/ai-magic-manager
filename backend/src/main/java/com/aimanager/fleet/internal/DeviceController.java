package com.aimanager.fleet.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import jakarta.validation.Valid;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.HttpStatus;

/** IDs come from credential context, never a client-supplied tenant/device identifier. */
@RestController
@RequestMapping("/api/v1/device-api")
@SecurityRequirement(name = "deviceBearer")
class DeviceController {
    private final HeartbeatService heartbeats;
    private final DeviceCredentials credentials;
    DeviceController(HeartbeatService heartbeats, DeviceCredentials credentials) { this.heartbeats = heartbeats; this.credentials = credentials; }

    @PostMapping("/heartbeats")
    HeartbeatService.Accepted heartbeat(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal, @Valid @RequestBody Heartbeat input) {
        return heartbeats.accept(DeviceContext.from(principal), input);
    }

    @PostMapping("/credentials/rotate")
    DeviceCredentials.Issued rotate(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
        return credentials.rotate(DeviceContext.from(principal));
    }

    @PostMapping("/credentials/activate") @ResponseStatus(HttpStatus.NO_CONTENT)
    void activate(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
        credentials.activateRotation(DeviceContext.from(principal));
    }

    @PostMapping("/credentials/rotation/cancel") @ResponseStatus(HttpStatus.NO_CONTENT)
    void cancelRotation(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
        credentials.cancelRotation(DeviceContext.from(principal));
    }

    record Heartbeat(@Min(1) @Max(9007199254740991L) long sequence, @NotBlank @Size(max = 60) String agentVersion,
                     @NotNull @Size(max = 64) List<@NotNull @Valid CapabilityReport> capabilities) {}
    record CapabilityReport(@NotBlank @Pattern(regexp = "[a-z][a-z0-9_.]{1,63}") String key,
                            @NotNull Boolean reportedSupported, @NotNull GrantStatus grantStatus) {}
    enum GrantStatus { GRANTED, DENIED, NOT_REQUESTED, REVOKED, NOT_APPLICABLE }
}
