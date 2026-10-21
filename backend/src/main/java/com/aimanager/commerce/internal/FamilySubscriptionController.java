package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import java.util.Map;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
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

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}")
class FamilySubscriptionController {
  private final FamilySubscriptionService subscriptions;
  private final com.aimanager.identity.RecentAuthentication recent;
  private final org.springframework.jdbc.core.JdbcTemplate jdbc;
  private final FamilyDeviceAccessService devices;
  FamilySubscriptionController(FamilySubscriptionService subscriptions,com.aimanager.identity.RecentAuthentication recent,org.springframework.jdbc.core.JdbcTemplate jdbc,FamilyDeviceAccessService devices) {
    this.subscriptions = subscriptions;this.recent=recent;this.jdbc=jdbc;this.devices=devices;
  }

  @GetMapping("/family-device-access")
  ResponseEntity<?> devices(@PathVariable String tenantId,@AuthenticationPrincipal Jwt actor) {
    var view=devices.read(tenantId,actor.getSubject());
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .eTag(com.aimanager.shared.ResourceVersions.tag(view.version())).body(view);
  }

  @PutMapping("/family-device-access/selection")
  ResponseEntity<?> selection(@PathVariable String tenantId,@AuthenticationPrincipal Jwt actor,
      @RequestHeader(value="If-Match",required=false) String version,
      @RequestHeader(value="Idempotency-Key",required=false) String key,@RequestBody SelectionInput input) {
    if(input==null)throw DomainException.invalid("INVALID_FAMILY_SELECTION");
    recent.requireForTenant(actor,tenantId,jdbc);
    var view=devices.select(tenantId,actor.getSubject(),input.deviceId(),input.registrationId(),com.aimanager.shared.ResourceVersions.require(version),key);
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization")
        .eTag(com.aimanager.shared.ResourceVersions.tag(view.version())).body(view);
  }

  @GetMapping("/subscription-offers")
  ResponseEntity<?> offers(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor) {
    return response(subscriptions.offers(tenantId, actor.getSubject()));
  }

  @GetMapping("/subscription")
  ResponseEntity<?> subscription(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor) {
    return response(subscriptions.subscription(tenantId, actor.getSubject()));
  }

  @PostMapping("/subscription/trial")
  ResponseEntity<?> trial(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor, @RequestBody TrialInput input) {
    if (input == null) throw DomainException.invalid("INVALID_TRIAL_REQUEST");
    return response(subscriptions.startTrial(tenantId, actor, input.deviceId()));
  }

  @PostMapping("/orders")
  ResponseEntity<?> order(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value="Idempotency-Key", required=false) String key, @RequestBody OrderInput input) {
    if (input == null) throw DomainException.invalid("INVALID_FAMILY_ORDER");
    return response(subscriptions.createOrder(tenantId, actor.getSubject(), key, input.planKey(),input.offerVersion()));
  }

  @GetMapping("/orders")
  ResponseEntity<?> orders(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue="50") int limit, @RequestParam(required=false) String cursor) {
    return response(subscriptions.orders(tenantId, actor.getSubject(), limit, cursor));
  }

  @GetMapping("/orders/{orderId}")
  ResponseEntity<?> order(@PathVariable String tenantId, @PathVariable String orderId, @AuthenticationPrincipal Jwt actor) {
    return response(subscriptions.getOrder(tenantId, actor.getSubject(), orderId));
  }

  @PostMapping("/orders/{orderId}/payment-attempts")
  ResponseEntity<?> paymentAttempt(@PathVariable String tenantId, @PathVariable String orderId, @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value="Idempotency-Key", required=false) String key, @RequestBody(required=false) EmptyInput input) {
    return response(subscriptions.paymentAttempt(tenantId, actor.getSubject(), orderId, key));
  }

  @GetMapping("/orders/{orderId}/payment-attempts")
  ResponseEntity<?> paymentAttempts(@PathVariable String tenantId, @PathVariable String orderId, @AuthenticationPrincipal Jwt actor) {
    return response(Map.of("items", subscriptions.paymentAttempts(tenantId, actor.getSubject(), orderId)));
  }

  @PostMapping("/orders/{orderId}/payment-verifications")
  ResponseEntity<?> verifyPayment(@PathVariable String tenantId, @PathVariable String orderId, @AuthenticationPrincipal Jwt actor,
      @RequestBody(required=false) EmptyInput input) {
    return response(subscriptions.verifyPayment(tenantId, actor.getSubject(), orderId));
  }

  @PostMapping("/orders/{orderId}/refund-requests")
  ResponseEntity<?> requestRefund(@PathVariable String tenantId, @PathVariable String orderId, @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value="Idempotency-Key", required=false) String key, @RequestBody RefundInput input) {
    if (input == null) throw DomainException.invalid("INVALID_REFUND_REASON");
    recent.requireForTenant(actor,tenantId,jdbc);
    var request = subscriptions.requestRefund(tenantId, actor.getSubject(), orderId, key, input.reason());
    return response(request);
  }
  @GetMapping("/orders/{orderId}/refund-requests")
  ResponseEntity<?> orderRefunds(@PathVariable String tenantId,@PathVariable String orderId,@AuthenticationPrincipal Jwt actor){
    return response(Map.of("items",subscriptions.refundsForOrder(tenantId,actor.getSubject(),orderId)));
  }

  @GetMapping("/refund-requests")
  ResponseEntity<?> refunds(@PathVariable String tenantId, @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue="50") int limit, @RequestParam(required=false) String cursor) {
    return response(subscriptions.refunds(tenantId, actor.getSubject(), limit, cursor));
  }

  @GetMapping("/refund-requests/{refundId}")
  ResponseEntity<?> refund(@PathVariable String tenantId, @PathVariable String refundId, @AuthenticationPrincipal Jwt actor) {
    return response(subscriptions.getRefund(tenantId, actor.getSubject(), refundId));
  }

  @PostMapping("/refund-requests/{refundId}/submissions")
  ResponseEntity<?> submitRefund(@PathVariable String tenantId, @PathVariable String refundId, @AuthenticationPrincipal Jwt actor,
      @RequestBody(required=false) EmptyInput input) {
    recent.requireForTenant(actor,tenantId,jdbc);
    return response(subscriptions.submitRefund(tenantId, actor.getSubject(), refundId));
  }

  @PostMapping("/refund-requests/{refundId}/verifications")
  ResponseEntity<?> verifyRefund(@PathVariable String tenantId, @PathVariable String refundId, @AuthenticationPrincipal Jwt actor,
      @RequestBody(required=false) EmptyInput input) {
    return response(subscriptions.verifyRefund(tenantId, actor.getSubject(), refundId));
  }

  static ResponseEntity<?> response(Object body) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary", "Authorization").body(body);
  }
  record OrderInput(String planKey,Long offerVersion) {}
  record TrialInput(String deviceId) {}
  record RefundInput(String reason) {}
  record EmptyInput() {}
  record SelectionInput(String deviceId,String registrationId) {}
}
