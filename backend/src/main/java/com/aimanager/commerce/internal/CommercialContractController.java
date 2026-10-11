package com.aimanager.commerce.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import java.net.URI;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Four-eye contract review. The external assertion is verified before the database transaction. */
@RestController
@RequestMapping("/api/v1/platform/contracts")
class CommercialContractController {
  private final CommercialContractService contracts;
  private final ContractEvidenceVerifier verifier;
  private final RecentAuthentication recent;
  private final boolean evidenceEnabled;

  CommercialContractController(
      CommercialContractService contracts,
      ContractEvidenceVerifier verifier,
      RecentAuthentication recent,
      @Value("${manager.contract.evidence-enabled:false}") boolean evidenceEnabled) {
    this.contracts = contracts;
    this.verifier = verifier;
    this.recent = recent;
    this.evidenceEnabled = evidenceEnabled;
  }

  @GetMapping("/capabilities")
  ResponseEntity<ContractCapabilities> capabilities(Authentication authentication) {
    CommercialContractService.requireEither(authentication);
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(new ContractCapabilities(evidenceEnabled, "CN", "CONTRACT", true, true, true));
  }

  @PostMapping
  ResponseEntity<CommercialContractService.ReviewView> create(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @RequestBody CreateInput input) {
    CommercialContractService.require(authentication, CommercialContractService.MANAGE);
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_CONTRACT_REVIEW");
    ContractEvidence evidence = verifier.verify(input.evidence());
    var outcome = contracts.create(authentication, actor, input.id(), evidence);
    return ResponseEntity.status(outcome.created() ? HttpStatus.CREATED : HttpStatus.OK)
        .location(URI.create("/api/v1/platform/contracts/" + outcome.review().id()))
        .eTag(ResourceVersions.tag(outcome.review().version()))
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(outcome.review());
  }

  @PostMapping("/{id}/approve")
  ResponseEntity<CommercialContractService.ReviewView> approve(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody(required = false) ActionInput input) {
    return response(
        contracts.approve(
            authentication, actor, id, ResourceVersions.require(ifMatch), reason(input)));
  }

  @PostMapping("/{id}/reject")
  ResponseEntity<CommercialContractService.ReviewView> reject(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody(required = false) ActionInput input) {
    return response(
        contracts.reject(
            authentication, actor, id, ResourceVersions.require(ifMatch), reason(input)));
  }

  @GetMapping("/{id}")
  ResponseEntity<CommercialContractService.ReviewView> get(
      Authentication authentication, @PathVariable String id) {
    return response(contracts.platformGet(authentication, id));
  }

  @GetMapping("/{id}/history")
  ResponseEntity<CommercialContractService.PlatformHistoryPage> history(
      Authentication authentication,
      @PathVariable String id,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) Long beforeVersion) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(contracts.platformHistory(authentication, id, limit, beforeVersion));
  }

  @GetMapping
  ResponseEntity<ItemPage<CommercialContractService.ReviewView>> list(
      Authentication authentication,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(contracts.platformList(authentication, limit, cursor));
  }

  private static ResponseEntity<CommercialContractService.ReviewView> response(
      CommercialContractService.ReviewView review) {
    return ResponseEntity.ok()
        .eTag(ResourceVersions.tag(review.version()))
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(review);
  }

  record CreateInput(String id, String evidence) {}

  record ActionInput(String reason) {}

  record ContractCapabilities(
      boolean submissionEnabled,
      String region,
      String channel,
      boolean recentAuthenticationRequired,
      boolean independentApprovalRequired,
      boolean customerAcceptanceRequired) {}

  private static String reason(ActionInput input) {
    return input == null ? null : input.reason();
  }
}
