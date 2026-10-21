package com.aimanager.commerce.internal;

import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/** Only the signature-verified gateway result reaches the ledger. */
@RestController
class FamilyWechatNotificationController {
  private final FamilySubscriptionService subscriptions;
  FamilyWechatNotificationController(FamilySubscriptionService subscriptions) { this.subscriptions = subscriptions; }

  @PostMapping("/api/v1/payments/wechat/notifications")
  ResponseEntity<?> notification(@RequestHeader Map<String,String> headers, @RequestBody String rawBody) {
    subscriptions.notification(headers, rawBody);
    return ResponseEntity.ok(Map.of("code","SUCCESS","message","成功"));
  }
}
