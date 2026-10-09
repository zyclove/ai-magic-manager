package com.aimanager.subject.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.subject.Subject;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/subjects")
class SubjectController {
    private final SubjectService subjects;
    SubjectController(SubjectService subjects) { this.subjects = subjects; }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    Subject create(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                   @Valid @RequestBody CreateSubject input,
                   @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return subjects.create(tenantId, actor.getSubject(), input.nickname(), input.ageBand(), key);
    }

    @GetMapping
    ItemPage<Subject> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                           @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return subjects.list(tenantId, actor.getSubject(), limit, cursor);
    }

    @GetMapping("/{subjectId}")
    ResponseEntity<Subject> get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String subjectId) {
        var result = subjects.get(tenantId, actor.getSubject(), subjectId);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(result.version())).body(result);
    }

    @PatchMapping("/{subjectId}")
    ResponseEntity<Subject> update(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String subjectId,
                                   @Valid @RequestBody CreateSubject input,
                                   @RequestHeader(name = "If-Match", required = false) String ifMatch) {
        var result = subjects.update(tenantId, actor.getSubject(), subjectId, input.nickname(), input.ageBand(), ifMatch);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(result.version())).body(result);
    }

    @PostMapping("/{subjectId}/archive")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void archive(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String subjectId,
                 @RequestHeader(name = "If-Match", required = false) String ifMatch) {
        subjects.archive(tenantId, actor, subjectId, ifMatch);
    }

    record CreateSubject(@NotBlank @Size(max = 60) String nickname, @NotNull Subject.AgeBand ageBand) {}
}
