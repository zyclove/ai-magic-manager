package com.aimanager.schedule.internal;

import com.aimanager.schedule.*;
import com.aimanager.shared.ItemPage;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.time.Instant;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/schedules")
class ScheduleController {
    private final ScheduleService schedules;
    ScheduleController(ScheduleService schedules) { this.schedules = schedules; }
    @PostMapping @ResponseStatus(HttpStatus.CREATED)
    ScheduleEntry create(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @Valid @RequestBody CreateSchedule input,
                         @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return schedules.create(tenantId, actor.getSubject(), input, key);
    }
    @GetMapping ItemPage<ScheduleEntry> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                            @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return schedules.list(tenantId, actor.getSubject(), limit, cursor);
    }
    @GetMapping("/{scheduleId}") ScheduleEntry get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String scheduleId) {
        return schedules.requireDefinition(tenantId, actor.getSubject(), scheduleId);
    }
    @GetMapping("/{scheduleId}/evaluation")
    ScheduleEngine.Decision evaluate(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String scheduleId,
                                     @RequestParam Instant at) {
        return ScheduleEngine.evaluate(schedules.requireDefinition(tenantId, actor.getSubject(), scheduleId).definition(), at);
    }
    record CreateSchedule(@NotBlank @Size(max = 100) String name, @NotNull @Valid ScheduleDefinition definition) {}
}
