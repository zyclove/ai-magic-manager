package com.aimanager.observation.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.observation.ObservationAuthorizationChanged;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.ZoneId;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.EventListener;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class UsageObservationService {
    private static final long MAX_SEQUENCE = 9007199254740991L;
    private static final long DAY_MILLIS = 86400000L;
    private static final long CLOCK_TOLERANCE_MILLIS = 300000L;
    private final JdbcTemplate jdbc;
    private final DeviceAccess devices;
    private final DeviceCredentials credentials;
    private final ObservationSettingsService settings;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final Clock clock;
    private final long minimumIntervalMillis, retentionMillis;
    private final int maxRetainedBatches;

    UsageObservationService(JdbcTemplate jdbc, DeviceAccess devices, DeviceCredentials credentials,
            ObservationSettingsService settings, ObjectMapper mapper, AuditService audit, Clock clock,
            @Value("${manager.observations.minimum-report-interval-seconds:60}") long interval,
            @Value("${manager.observations.retention-days:30}") long days,
            @Value("${manager.observations.max-retained-batches:168}") int maxBatches) {
        if (interval < 1 || interval > 3600 || days < 1 || days > 90 || maxBatches < 1 || maxBatches > 1024) {
            throw new IllegalArgumentException("Invalid observation limits");
        }
        this.jdbc = jdbc; this.devices = devices; this.credentials = credentials; this.settings = settings;
        this.mapper = mapper; this.audit = audit; this.clock = clock;
        minimumIntervalMillis = interval * 1000; retentionMillis = days * DAY_MILLIS;
        maxRetainedBatches = maxBatches;
    }

    @Transactional(timeout = 10)
    public Accepted report(DeviceContext identity, UsageObservationController.Report input) {
        devices.lockActive(identity);
        credentials.requireActive(identity);
        settings.requireUsage(identity, input.authorizationVersion());
        var normalized = normalize(input);
        String payload = json(normalized), hash = SecretMaterial.hash(payload);
        var heads = jdbc.query("SELECT sequence_number,report_id,request_hash,received_at FROM usage_observation_heads "
                + "WHERE tenant_id=? AND device_id=? AND registration_id=? FOR UPDATE",
            (row, index) -> new Head(row.getLong(1), row.getString(2), row.getString(3), row.getLong(4)),
            identity.tenantId(), identity.deviceId(), identity.registrationId());
        long now = clock.millis();
        if (!heads.isEmpty()) {
            var head = heads.get(0);
            if (input.sequence() == head.sequence()) {
                if (!hash.equals(head.hash())) throw conflict("USAGE_SEQUENCE_CONFLICT");
                return new Accepted(identity.registrationId(), head.reportId(), head.sequence(), head.receivedAt());
            }
            if (input.sequence() < head.sequence()) throw conflict("USAGE_STALE_SEQUENCE");
            if (now - head.receivedAt() < minimumIntervalMillis) {
                throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "OBSERVATION_REPORT_RATE_LIMITED");
            }
        }
        if (jdbc.queryForObject("SELECT COUNT(*) FROM usage_observation_batches WHERE tenant_id=? AND device_id=? AND report_id=?",
                Integer.class, identity.tenantId(), identity.deviceId(), input.reportId()) != 0) {
            throw conflict("USAGE_REPORT_ID_CONFLICT");
        }
        jdbc.update("INSERT INTO usage_observation_batches(tenant_id,device_id,registration_id,sequence_number,"
                + "report_id,authorization_version,payload_json,received_at) VALUES(?,?,?,?,?,?,?,?)",
            identity.tenantId(), identity.deviceId(), identity.registrationId(), input.sequence(), input.reportId(),
            input.authorizationVersion(), payload, now);
        if (heads.isEmpty()) {
            jdbc.update("INSERT INTO usage_observation_heads(tenant_id,device_id,registration_id,sequence_number,"
                    + "report_id,request_hash,received_at) VALUES(?,?,?,?,?,?,?)", identity.tenantId(), identity.deviceId(),
                identity.registrationId(), input.sequence(), input.reportId(), hash, now);
        } else {
            jdbc.update("UPDATE usage_observation_heads SET sequence_number=?,report_id=?,request_hash=?,received_at=? "
                    + "WHERE tenant_id=? AND device_id=? AND registration_id=?", input.sequence(), input.reportId(), hash, now,
                identity.tenantId(), identity.deviceId(), identity.registrationId());
        }
        prune(identity, now);
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), "USAGE_OBSERVATION_REPORTED", input.reportId());
        return new Accepted(identity.registrationId(), input.reportId(), input.sequence(), now);
    }

    private UsageObservationController.Report normalize(UsageObservationController.Report input) {
        long now = clock.millis();
        if (input.queryStart() >= input.queryEnd() || input.queryEnd() > input.observedAt()
                || input.queryEnd() - input.queryStart() > 2 * DAY_MILLIS
                || input.observedAt() > now + CLOCK_TOLERANCE_MILLIS || input.observedAt() < now - 7 * DAY_MILLIS) {
            throw DomainException.invalid("INVALID_OBSERVATION_WINDOW");
        }
        try { ZoneId.of(input.timeZone()); }
        catch (java.time.DateTimeException failure) { throw DomainException.invalid("INVALID_TIME_ZONE"); }
        var identities = new HashSet<String>();
        var apps = new ArrayList<UsageObservationController.Application>();
        for (var app : input.applications()) {
            if (app.firstTimeStamp() > app.lastTimeStamp() || app.lastTimeStamp() > input.observedAt() + CLOCK_TOLERANCE_MILLIS
                    || app.firstTimeStamp() < input.observedAt() - 7 * DAY_MILLIS
                    || app.foregroundMillis() > app.lastTimeStamp() - app.firstTimeStamp()) {
                throw DomainException.invalid("INVALID_OBSERVATION_WINDOW");
            }
            if (!identities.add(app.packageName() + "|" + app.firstTimeStamp() + "|" + app.lastTimeStamp())) {
                throw DomainException.invalid("DUPLICATE_USAGE_APPLICATION");
            }
            apps.add(new UsageObservationController.Application(app.packageName(), app.displayName().strip(),
                app.firstTimeStamp(), app.lastTimeStamp(), app.foregroundMillis()));
        }
        apps.sort(Comparator.comparing(UsageObservationController.Application::packageName)
            .thenComparing(UsageObservationController.Application::firstTimeStamp)
            .thenComparing(UsageObservationController.Application::lastTimeStamp));
        return new UsageObservationController.Report(input.reportId(), input.sequence(), input.authorizationVersion(),
            input.source(), input.profile(), input.queryStart(), input.queryEnd(), input.observedAt(), input.timeZone(), List.copyOf(apps));
    }

    Page list(String tenant, String actor, String deviceId, int limit, String cursor) {
        var device = devices.requireVisible(tenant, actor, deviceId);
        if (limit < 1 || limit > 20) throw DomainException.invalid("INVALID_PAGE_SIZE");
        long before = MAX_SEQUENCE + 1;
        if (cursor != null) {
            try {
                if (!cursor.matches("[1-9][0-9]{0,15}")) throw new NumberFormatException();
                before = Long.parseLong(cursor);
                if (before > MAX_SEQUENCE) throw new NumberFormatException();
            } catch (NumberFormatException failure) { throw DomainException.invalid("INVALID_CURSOR"); }
        }
        var rows = jdbc.query("SELECT payload_json,received_at FROM usage_observation_batches "
                + "WHERE tenant_id=? AND device_id=? AND registration_id=? AND sequence_number<? AND received_at>=? "
                + "ORDER BY sequence_number DESC LIMIT ?",
            (row, index) -> batch(device.registrationId(), parse(row.getString(1)), row.getLong(2)),
            tenant, deviceId, device.registrationId(), before, clock.millis() - retentionMillis, limit + 1);
        boolean more = rows.size() > limit;
        var page = List.copyOf(rows.subList(0, Math.min(rows.size(), limit)));
        return new Page(page, more ? Long.toString(page.get(page.size() - 1).sequence()) : null);
    }

    private Batch batch(String registration, UsageObservationController.Report r, long receivedAt) {
        return new Batch(registration, r.reportId(), r.sequence(), r.authorizationVersion(), r.profile(),
            r.queryStart(), r.queryEnd(), r.observedAt(), r.timeZone(), r.applications(), receivedAt,
            "OS_AGGREGATE", "AGENT_REPORTED_UNVERIFIED");
    }

    private void prune(DeviceContext identity, long now) {
        var sequences = jdbc.queryForList("SELECT sequence_number FROM usage_observation_batches WHERE tenant_id=? "
                + "AND device_id=? AND registration_id=? ORDER BY sequence_number DESC LIMIT ?", Long.class,
            identity.tenantId(), identity.deviceId(), identity.registrationId(), maxRetainedBatches + 1);
        if (sequences.size() > maxRetainedBatches) {
            jdbc.update("DELETE FROM usage_observation_batches WHERE tenant_id=? AND device_id=? AND registration_id=? "
                    + "AND sequence_number<?", identity.tenantId(), identity.deviceId(), identity.registrationId(),
                sequences.get(maxRetainedBatches - 1));
        }
        jdbc.update("DELETE FROM usage_observation_batches WHERE tenant_id=? AND device_id=? AND registration_id=? AND received_at<?",
            identity.tenantId(), identity.deviceId(), identity.registrationId(), now - retentionMillis);
    }

    @EventListener
    @Transactional(propagation = Propagation.MANDATORY)
    public void authorizationChanged(ObservationAuthorizationChanged event) {
        if (!event.usageEnabled()) {
            jdbc.update("DELETE FROM usage_observation_batches WHERE tenant_id=? AND device_id=? AND registration_id=?",
                event.tenantId(), event.deviceId(), event.registrationId());
            jdbc.update("DELETE FROM usage_observation_heads WHERE tenant_id=? AND device_id=? AND registration_id=?",
                event.tenantId(), event.deviceId(), event.registrationId());
        }
    }

    /** 逐主键小批删除；不反向取得设备/授权锁，避免与报告事务形成锁环。 */
    @Scheduled(fixedDelayString = "${manager.observations.retention-delay-millis:300000}",
               initialDelayString = "${manager.observations.retention-delay-millis:300000}")
    @Transactional(timeout = 10)
    public void purgeExpired() {
        long cutoff = clock.millis() - retentionMillis;
        var expired = jdbc.query("SELECT tenant_id,device_id,sequence_number FROM usage_observation_batches "
                + "WHERE received_at<? ORDER BY received_at LIMIT 100",
            (row, index) -> new Expired(row.getString(1), row.getString(2), row.getLong(3)), cutoff);
        for (var item : expired) {
            jdbc.update("DELETE FROM usage_observation_batches WHERE tenant_id=? AND device_id=? AND sequence_number=? AND received_at<?",
                item.tenant(), item.device(), item.sequence(), cutoff);
        }
    }

    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Usage serialization failed", failure); }
    }
    private UsageObservationController.Report parse(String value) {
        try { return mapper.readValue(value, UsageObservationController.Report.class); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Usage snapshot unreadable", failure); }
    }
    private DomainException conflict(String code) { return new DomainException(HttpStatus.CONFLICT, code); }
    record Accepted(String registrationId, String reportId, long sequence, long receivedAt) {}
    record Head(long sequence, String reportId, String hash, long receivedAt) {}
    record Batch(String registrationId, String reportId, long sequence, long authorizationVersion, String profile,
                 long queryStart, long queryEnd, long observedAt, String timeZone,
                 List<UsageObservationController.Application> applications, long receivedAt,
                 String precision, String evidenceStatus) {}
    record Page(List<Batch> items, String nextCursor) {}
    private record Expired(String tenant, String device, long sequence) {}
}
