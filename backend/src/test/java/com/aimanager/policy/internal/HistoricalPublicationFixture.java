package com.aimanager.policy.internal;

import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.policy.PolicyPublication;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;

/** Test-only historical data: exact production request DTO, journal and immutable version.
 * No event or outbox is emitted; the fixture cannot activate a provider or certify execution. */
public final class HistoricalPublicationFixture {
    private HistoricalPublicationFixture() {}

    public static PolicyPublication enforce(JdbcTemplate jdbc, IdempotencyService idempotency,
        String tenant, String actor, String subject, String policy, long revision,
        String preview, String hash, String key) {
        var input = new PolicyController.Publish(preview, hash, PolicyPublication.Mode.ENFORCE);
        return idempotency.execute(tenant, actor, "policy.publish", key,
            Map.of("policyId", policy, "revision", revision, "input", input), PolicyPublication.class, () -> {
                String version = UUID.randomUUID().toString(), publication = UUID.randomUUID().toString();
                long now = Instant.now().toEpochMilli();
                String snapshot = jdbc.queryForObject("SELECT snapshot_json FROM policy_previews WHERE tenant_id=? AND id=?",
                    String.class, tenant, preview);
                jdbc.update("UPDATE policy_drafts SET next_sequence=1 WHERE tenant_id=? AND id=?", tenant, policy);
                jdbc.update("INSERT INTO policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    tenant, version, policy, revision, 1, preview, hash, "ENFORCE", snapshot, now);
                jdbc.update("INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at) VALUES(?,?,?,?,?)",
                    tenant, publication, version, "NEEDS_REVIEW", now);
                return new PolicyPublication(publication, version, 1, PolicyPublication.Mode.ENFORCE, "NEEDS_REVIEW", now);
            }, ignored -> ResponseOwnership.subjects(tenant, List.of(subject)));
    }
}
