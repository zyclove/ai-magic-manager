package com.aimanager.notification.internal;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;
import java.util.List;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/notifications")
class NotificationController {
  private final NotificationService notifications;

  NotificationController(NotificationService notifications) {
    this.notifications = notifications;
  }

  @GetMapping
  NotificationService.Page list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor,
      @RequestParam(defaultValue = "false") boolean unreadOnly) {
    return notifications.list(tenantId, actor.getSubject(), limit, cursor, unreadOnly);
  }

  @GetMapping("/unread-count")
  NotificationService.UnreadCount unread(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
    return notifications.unreadCount(tenantId, actor.getSubject());
  }

  @PutMapping("/{id}/read")
  NotificationService.ReadReceipt read(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
    return notifications.read(tenantId, actor.getSubject(), id);
  }

  @PostMapping("/read")
  NotificationService.ReadBatch readBatch(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Selection selection) {
    return notifications.readBatch(tenantId, actor.getSubject(), selection.ids());
  }

  record Selection(@NotEmpty @Size(max = 50) List<String> ids) {}
}
