package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import java.net.URI;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Platform-only catalog drafts. No endpoint here charges a buyer or creates entitlements. */
@RestController
@RequestMapping("/api/v1/platform/catalog/offers")
class CommercialCatalogController {
  private final CommercialCatalogService catalog;

  CommercialCatalogController(CommercialCatalogService catalog) {
    this.catalog = catalog;
  }

  @PostMapping
  ResponseEntity<CommercialCatalogService.OfferView> create(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @RequestBody CreateInput input) {
    if (input == null) throw DomainException.invalid("INVALID_COMMERCIAL_OFFER");
    var outcome = catalog.create(authentication, actor, input.id(), input.offer());
    return ResponseEntity.status(outcome.created() ? HttpStatus.CREATED : HttpStatus.OK)
        .location(URI.create("/api/v1/platform/catalog/offers/" + outcome.offer().id()))
        .eTag(ResourceVersions.tag(outcome.offer().revision()))
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(outcome.offer());
  }

  @PutMapping("/{id}")
  ResponseEntity<CommercialCatalogService.OfferView> revise(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody CommercialOfferDraft input) {
    return response(
        catalog.revise(authentication, actor, id, ResourceVersions.require(ifMatch), input));
  }

  @PostMapping("/{id}/submit")
  ResponseEntity<CommercialCatalogService.OfferView> submit(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody(required = false) ActionInput input) {
    return response(
        catalog.submit(
            authentication, actor, id, ResourceVersions.require(ifMatch), reason(input)));
  }

  @PostMapping("/{id}/approve")
  ResponseEntity<CommercialCatalogService.OfferView> approve(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody(required = false) ActionInput input) {
    return response(
        catalog.approve(
            authentication, actor, id, ResourceVersions.require(ifMatch), reason(input)));
  }

  @PostMapping("/{id}/retire")
  ResponseEntity<CommercialCatalogService.OfferView> retire(
      Authentication authentication,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody(required = false) ActionInput input) {
    return response(
        catalog.retire(
            authentication, actor, id, ResourceVersions.require(ifMatch), reason(input)));
  }

  @GetMapping("/{id}")
  ResponseEntity<CommercialCatalogService.OfferView> get(
      Authentication authentication, @PathVariable String id) {
    return response(catalog.get(authentication, id));
  }

  @GetMapping("/{id}/history")
  ResponseEntity<CommercialCatalogService.HistoryPage> history(
      Authentication authentication,
      @PathVariable String id,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) Long beforeRevision) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(catalog.history(authentication, id, limit, beforeRevision));
  }

  @GetMapping
  ResponseEntity<ItemPage<CommercialCatalogService.OfferView>> list(
      Authentication authentication,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(catalog.list(authentication, limit, cursor));
  }

  private ResponseEntity<CommercialCatalogService.OfferView> response(
      CommercialCatalogService.OfferView offer) {
    return ResponseEntity.ok()
        .eTag(ResourceVersions.tag(offer.revision()))
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(offer);
  }

  record CreateInput(String id, CommercialOfferDraft offer) {}

  record ActionInput(String reason) {}

  private static String reason(ActionInput input) {
    return input == null ? null : input.reason();
  }
}
