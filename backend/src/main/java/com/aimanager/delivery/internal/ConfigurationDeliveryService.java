package com.aimanager.delivery.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.delivery.*;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.policy.*;
import com.aimanager.shared.*;
import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Owns configuration transport only. Receipt stages never mutate policy enforcement or fleet capability facts. */
@Service
class ConfigurationDeliveryService implements FamilyConfigurationPublisher {
    private static final long MAX_CURSOR = 9007199254740991L;
    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final Clock clock;
    private final DeviceAccess devices;
    private final DeviceCredentials credentials;
    private final ConfigurationSigner signer;
    private final PolicyReadAccess policies;
    private final AuditService audit;
    private final ApplicationEventPublisher events;
    private final long lifetimeMillis;
    private final String issuer;
    ConfigurationDeliveryService(JdbcTemplate jdbc, ObjectMapper mapper, Clock clock, DeviceAccess devices,
                                 DeviceCredentials credentials, ConfigurationSigner signer, PolicyReadAccess policies,
                                 AuditService audit, ApplicationEventPublisher events,
                                 @Value("${manager.delivery.delivery-ttl-seconds:86400}") long lifetime,
                                 @Value("${manager.delivery.issuer:ai-manager}") String issuer) {
        if (lifetime < 60 || lifetime > 86400 || issuer.isBlank() || issuer.length() > 200)
            throw new IllegalArgumentException("Invalid configuration delivery settings");
        this.jdbc = jdbc; this.mapper = mapper; this.clock = clock; this.devices = devices; this.credentials = credentials;
        this.signer = signer; this.policies = policies; this.audit = audit; this.events = events; this.issuer = issuer;
        this.lifetimeMillis = lifetime * 1000;
    }

    /** Synchronous projection shares the policy transaction; only small notices use asynchronous durable listeners. */
    @EventListener
    @Transactional(propagation = Propagation.MANDATORY)
    public void prepare(PolicyConfigurationRecorded event) {
        if (event.version().mode() != PolicyPublication.Mode.CONFIGURE_ONLY) throw new IllegalArgumentException("Unsupported configuration mode");
        var current = new TreeMap<String, PolicySnapshot.Target>();
        event.version().snapshot().targets().forEach(t -> current.put(t.registrationId(), t));
        var all = new TreeMap<String, PolicySnapshot.Target>();
        event.previousTargets().forEach(t -> all.put(t.registrationId(), t)); all.putAll(current);
        for (var target : all.values()) {
            lockHead(event.tenantId(), target.registrationId(), target.deviceId());
            var previous = currentDelivery(event.tenantId(), target.registrationId(), event.version().policyId());
            if (previous != null && previous.sourceSequence() >= event.version().sequence()) continue;
            if (previous != null) jdbc.update("UPDATE configuration_deliveries SET state='SUPERSEDED' WHERE tenant_id=? AND id=?", event.tenantId(), previous.id());
            long cursor = nextCursor(event.tenantId(), target.registrationId());
            boolean selected = current.containsKey(target.registrationId());
            var document = selected ? document(event.version().snapshot(), target) : null;
            String delivery = insert(event.tenantId(), target.deviceId(), target.registrationId(), event.publicationId(), event.version().id(),
                event.version().policyId(), event.version().sequence(), cursor, selected ? "UPSERT_CONFIGURATION" : "REMOVE_CONFIGURATION", document);
            setStream(event.tenantId(), target.registrationId(), event.version().policyId(), delivery, previous == null);
            events.publishEvent(new ConfigurationChangedNotice(UUID.randomUUID().toString(), event.tenantId(), target.deviceId(), target.registrationId(),
                event.version().policyId(), cursor, clock.millis(), event.correlationId()));
        }
    }
    private ConfigurationDocument document(PolicySnapshot snapshot, PolicySnapshot.Target target) {
        var appIds = new HashSet<String>(); var scheduleIds = new HashSet<String>();
        for (var rule : target.rules()) { if (rule.applicationId() != null) appIds.add(rule.applicationId()); if (rule.scheduleId() != null) scheduleIds.add(rule.scheduleId()); }
        return new ConfigurationDocument(snapshot.name(), target.rules(), snapshot.applications().stream().filter(a -> appIds.contains(a.id())).toList(),
            snapshot.schedules().stream().filter(s -> scheduleIds.contains(s.id())).toList(), snapshot.protectedPackageExemptions());
    }
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void publish(String tenant,String actor,List<String> deviceIds,String policy,long version,FamilyAssistanceDocument rules) {
        publishRetainingExisting(tenant,actor,deviceIds,policy,version,rules,deviceIds);
    }
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void publishRetainingExisting(String tenant,String actor,List<String> deviceIds,String policy,long version,
            FamilyAssistanceDocument rules,List<String> allowedDeviceIds,boolean allowRelaxation) {
        if (!new HashSet<>(deviceIds).containsAll(allowedDeviceIds)) throw new IllegalArgumentException("Unknown family renewal target");
        var allowed=new HashSet<>(allowedDeviceIds);
        var previous=new HashMap<String,Delivery>();
        var contents=new HashMap<String,FamilyAssistanceDocument>();
        var targets=new ArrayList<PolicySnapshot.Target>();
        for(String id:deviceIds.stream().sorted().toList()){
            var device=devices.lockVisibleActive(tenant,actor,id);
            if(device.platform()!=com.aimanager.fleet.Device.Platform.ANDROID || !"BYOD".equals(device.managementMode()))throw DomainException.invalid("FAMILY_DEVICE_UNSUPPORTED");
            lockHead(tenant,device.registrationId(),id);
            var old=currentDelivery(tenant,device.registrationId(),policy);
            var existing=old==null || old.document()==null?null:old.document().familyAssistance();
            var content=allowed.contains(id) || allowRelaxation && existing!=null && relaxes(existing,rules)?rules:existing;
            // A device without prior family authority must never gain a new restriction by renewal.
            if(content==null)continue;
            if(old!=null)previous.put(id,old);
            contents.put(id,content);
            targets.add(new PolicySnapshot.Target(id,device.registrationId(),device.platform(),device.state(),device.managementMode(),device.osVersion(),device.version(),device.observationStatus(),List.of(),List.of()));
        }
        if(targets.isEmpty())return;
        long now=clock.millis();
        var exemptions=List.copyOf(SafetyCriticalPackages.withAdditional(""));
        var snapshot=new PolicySnapshot(1,"家庭辅助规则",List.of(),List.of(),List.of(),exemptions,List.copyOf(targets),null);
        String encoded=json(snapshot),hash=SecretMaterial.hash(encoded),preview=UUID.randomUUID().toString(),versionId=UUID.randomUUID().toString(),publication=UUID.randomUUID().toString();
        jdbc.update("INSERT INTO policy_drafts(tenant_id,id,name,kind,revision,next_sequence,rules_json,created_at,updated_at) VALUES(?,?,'家庭辅助规则','POLICY',?,?,'[]',?,?) ON DUPLICATE KEY UPDATE revision=VALUES(revision),next_sequence=VALUES(next_sequence),updated_at=VALUES(updated_at)",tenant,policy,version,version,now,now);
        jdbc.update("INSERT INTO policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at,creator_actor_key) VALUES(?,?,?,?,?,?,?,?,?)",tenant,preview,policy,version,hash,encoded,now,now+86400000,com.aimanager.identity.ActorKeys.key(actor));
        jdbc.update("INSERT INTO policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at) VALUES(?,?,?,?,?,?,?,'CONFIGURE_ONLY',?,?)",tenant,versionId,policy,version,version,preview,hash,encoded,now);
        jdbc.update("INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at) VALUES(?,?,?,'CONFIGURED_NOT_ENFORCED',?)",tenant,publication,versionId,now);
        for(var device:targets){
            var old=previous.get(device.deviceId());
            if(old!=null)jdbc.update("UPDATE configuration_deliveries SET state='SUPERSEDED' WHERE tenant_id=? AND id=?",tenant,old.id());
            long cursor=nextCursor(tenant,device.registrationId());
            var grants=jdbc.queryForList("SELECT not_after FROM family_temporary_grants WHERE tenant_id=? AND device_id=? AND registration_id=? AND not_after>? FOR UPDATE",Long.class,tenant,device.deviceId(),device.registrationId(),now);
            Long exception=grants.isEmpty()?null:grants.get(0);
            var content=contents.get(device.deviceId());
            var assistance=new FamilyAssistanceDocument(1,"FAMILY_ASSISTED",content.enabled(),content.dailyAllowanceSeconds(),content.timeZoneId(),content.meteredPackages(),content.allowedWindows(),now+7L*86400000,exception);
            var document=new ConfigurationDocument("家庭使用规则",List.of(),List.of(),List.of(),exemptions,assistance);
            String id=insert(tenant,device.deviceId(),device.registrationId(),publication,versionId,policy,version,cursor,"UPSERT_CONFIGURATION",document);
            setStream(tenant,device.registrationId(),policy,id,old==null);
        }
    }
    /** 每台设备独立比较，不能把“比孩子最新草稿宽松”当成“比所有设备旧规则宽松”。 */
    private boolean relaxes(FamilyAssistanceDocument previous,FamilyAssistanceDocument next) {
        if(!next.enabled())return true;
        if(!previous.enabled() || !previous.timeZoneId().equals(next.timeZoneId())
            || next.dailyAllowanceSeconds()<previous.dailyAllowanceSeconds()
            || !previous.meteredPackages().containsAll(next.meteredPackages()))return false;
        var before=allowedMinutes(previous.allowedWindows());
        before.andNot(allowedMinutes(next.allowedWindows()));
        return before.isEmpty();
    }
    private BitSet allowedMinutes(List<FamilyAssistanceDocument.Window> windows) {
        final int minutesPerDay=1440,minutesPerWeek=7*minutesPerDay;
        var result=new BitSet(minutesPerWeek);
        if(windows.isEmpty()){result.set(0,minutesPerWeek);return result;}
        for(var window:windows)for(int day:window.daysOfWeek()) {
            int start=(day-1)*minutesPerDay+window.startMinute();
            int duration=Math.floorMod(window.endMinute()-window.startMinute(),minutesPerDay);
            for(int i=0;i<duration;i++)result.set((start+i)%minutesPerWeek);
        }
        return result;
    }
    private void lockHead(String tenant, String registration, String device) {
        try { jdbc.update("INSERT INTO configuration_device_heads(tenant_id,registration_id,device_id) VALUES(?,?,?)", tenant, registration, device); }
        catch (DuplicateKeyException duplicate) { /* Existing head is read with a current row lock below. */ }
        var found = jdbc.queryForList("SELECT device_id FROM configuration_device_heads WHERE tenant_id=? AND registration_id=? FOR UPDATE", String.class, tenant, registration);
        if (found.size() != 1 || !device.equals(found.get(0))) throw DomainException.denied();
    }
    private long nextCursor(String tenant, String registration) {
        long cursor = jdbc.queryForObject("SELECT next_cursor FROM configuration_device_heads WHERE tenant_id=? AND registration_id=? FOR UPDATE", Long.class, tenant, registration);
        if (cursor >= MAX_CURSOR) throw new DomainException(HttpStatus.CONFLICT, "STREAM_CURSOR_EXHAUSTED");
        jdbc.update("UPDATE configuration_device_heads SET next_cursor=? WHERE tenant_id=? AND registration_id=?", cursor + 1, tenant, registration);
        return cursor + 1;
    }
    private String insert(String tenant, String device, String registration, String publication, String version, String policy,
                          long sequence, long cursor, String action, ConfigurationDocument document) {
        String id = UUID.randomUUID().toString(); long issued = clock.millis();
        jdbc.update("INSERT INTO configuration_deliveries(tenant_id,id,publication_id,version_id,policy_id,registration_id,device_id,source_sequence,device_cursor,action,document_json,issued_at,delivery_expires_at,state) "
            + "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'PENDING_SIGNATURE')", tenant, id, publication, version, policy, registration, device, sequence, cursor, action,
            document == null ? null : json(document), issued, issued + lifetimeMillis);
        return id;
    }
    private void setStream(String tenant, String registration, String policy, String id, boolean newStream) {
        if (newStream) jdbc.update("INSERT INTO configuration_streams(tenant_id,registration_id,policy_id,delivery_id) VALUES(?,?,?,?)", tenant, registration, policy, id);
        else jdbc.update("UPDATE configuration_streams SET delivery_id=? WHERE tenant_id=? AND registration_id=? AND policy_id=?", id, tenant, registration, policy);
    }
    private Delivery currentDelivery(String tenant, String registration, String policy) {
        var rows = jdbc.query("SELECT d.* FROM configuration_streams s JOIN configuration_deliveries d ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id "
            + "WHERE s.tenant_id=? AND s.registration_id=? AND s.policy_id=? FOR UPDATE", (row, index) -> map(row), tenant, registration, policy);
        return rows.isEmpty() ? null : rows.get(0);
    }
    private Delivery delivery(String tenant, String registration, String id) {
        var rows = jdbc.query("SELECT * FROM configuration_deliveries WHERE tenant_id=? AND registration_id=? AND id=? FOR UPDATE",
            (row, index) -> map(row), tenant, registration, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }

    @Transactional(timeout = 10)
    public Pull pull(DeviceContext identity, long after, int limit) {
        authenticate(identity); signer.requireConfigured();
        if (after < 0 || after > MAX_CURSOR || limit < 1 || limit > 50) throw DomainException.invalid("INVALID_DELIVERY_PAGE");
        long highWater = jdbc.queryForObject("SELECT next_cursor FROM configuration_device_heads WHERE tenant_id=? AND registration_id=? FOR UPDATE", Long.class,
            identity.tenantId(), identity.registrationId());
        if (after > highWater) throw DomainException.invalid("DELIVERY_CURSOR_AHEAD");
        var pending = jdbc.query("SELECT d.* FROM configuration_streams s JOIN configuration_deliveries d ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id "
                + "WHERE s.tenant_id=? AND s.registration_id=? AND d.device_cursor>? ORDER BY d.device_cursor LIMIT ? FOR UPDATE",
            (row, index) -> map(row), identity.tenantId(), identity.registrationId(), after, limit + 1);
        boolean hasMore = pending.size() > limit; var items = new ArrayList<Pulled>();
        for (var old : pending.subList(0, Math.min(limit, pending.size()))) {
            var item = old;
            if (item.expiresAt() <= clock.millis() && !"DEVICE_REPORTED_REJECTED".equals(item.state())) {
                // A retry changes transport identity, never content version or pagination order.
                jdbc.update("UPDATE configuration_deliveries SET state='EXPIRED_ATTEMPT' WHERE tenant_id=? AND id=?", identity.tenantId(), item.id());
                String id = insert(identity.tenantId(), identity.deviceId(), identity.registrationId(), item.publicationId(), item.versionId(), item.policyId(),
                    item.sourceSequence(), item.cursor(), item.action(), item.document());
                setStream(identity.tenantId(), identity.registrationId(), item.policyId(), id, false);
                item = delivery(identity.tenantId(), identity.registrationId(), id);
            }
            if (item.compactJws() == null) {
                var envelope = new ConfigurationEnvelope(1, issuer, "CONFIGURATION", "CONFIGURE_ONLY", item.action(), identity.tenantId(), identity.deviceId(),
                    identity.registrationId(), item.policyId(), item.versionId(), item.sourceSequence(), item.cursor(), item.id(), item.issuedAt(), item.expiresAt(), null, item.document());
                String signed = signer.sign(json(envelope));
                jdbc.update("UPDATE configuration_deliveries SET compact_jws=?,envelope_hash=?,signing_key_id=?,state='READY' WHERE tenant_id=? AND id=?",
                    signed, SecretMaterial.hash(signed), signer.activeKeyId(), identity.tenantId(), item.id());
            }
            jdbc.update("UPDATE configuration_deliveries SET first_served_at=COALESCE(first_served_at,?),state=CASE WHEN state IN ('PENDING_SIGNATURE','READY') THEN 'SERVED' ELSE state END "
                + "WHERE tenant_id=? AND id=?", clock.millis(), identity.tenantId(), item.id());
            item = delivery(identity.tenantId(), identity.registrationId(), item.id());
            items.add(new Pulled(item.id(), item.cursor(), item.compactJws(), item.expiresAt(), item.state()));
        }
        return new Pull(List.copyOf(items), hasMore ? items.get(items.size() - 1).cursor() : highWater, hasMore, clock.millis());
    }
    private void authenticate(DeviceContext identity) {
        devices.lockActive(identity); credentials.requireActive(identity); lockHead(identity.tenantId(), identity.registrationId(), identity.deviceId());
    }
    @Transactional(timeout = 10)
    public Map<String, Object> keys(DeviceContext identity) { authenticate(identity); return signer.publicKeys(); }

    @Transactional(timeout = 10)
    public ReceiptAccepted acknowledge(DeviceContext identity, DeliveryController.Receipt input) {
        authenticate(identity);
        if ((input.stage() == DeliveryController.Stage.REJECTED) != (input.reason() != null)) throw DomainException.invalid("INVALID_RECEIPT_REASON");
        var item = delivery(identity.tenantId(), identity.registrationId(), input.deliveryId());
        if (!identity.deviceId().equals(item.deviceId()) || item.compactJws() == null || item.firstServedAt() == null
            || input.cursor() != item.cursor() || !input.envelopeHash().equals(item.envelopeHash())) throw DomainException.denied();
        String requestHash = SecretMaterial.hash(json(input));
        var previous = jdbc.query("SELECT request_hash,response_json FROM configuration_receipts WHERE tenant_id=? AND registration_id=? AND id=? FOR UPDATE",
            (row, index) -> new PreviousReceipt(row.getString(1), row.getString(2)), identity.tenantId(), identity.registrationId(), input.receiptId());
        if (!previous.isEmpty()) {
            if (!requestHash.equals(previous.get(0).hash())) throw new DomainException(HttpStatus.CONFLICT, "RECEIPT_ID_CONFLICT");
            return read(previous.get(0).response(), ReceiptAccepted.class);
        }
        var latest = currentDelivery(identity.tenantId(), identity.registrationId(), item.policyId());
        boolean historical = latest == null || !item.id().equals(latest.id());
        long now = clock.millis(); String state = item.state();
        if (!historical) {
            if ("DEVICE_REPORTED_STORED".equals(state) && input.stage() == DeliveryController.Stage.REJECTED)
                throw new DomainException(HttpStatus.CONFLICT, "RECEIPT_PHASE_CONFLICT");
            if ("DEVICE_REPORTED_REJECTED".equals(state)) throw new DomainException(HttpStatus.CONFLICT, "DELIVERY_REJECTED_REPUBLISH_REQUIRED");
            if (input.stage() == DeliveryController.Stage.REJECTED) {
                state = "DEVICE_REPORTED_REJECTED";
                jdbc.update("UPDATE configuration_deliveries SET state=?,rejection_code=? WHERE tenant_id=? AND id=?", state, input.reason().name(), identity.tenantId(), item.id());
            } else if (input.stage() == DeliveryController.Stage.STORED) {
                state = "DEVICE_REPORTED_STORED";
                jdbc.update("UPDATE configuration_deliveries SET state=?,received_reported_at=COALESCE(received_reported_at,?),stored_reported_at=COALESCE(stored_reported_at,?) WHERE tenant_id=? AND id=?",
                    state, now, now, identity.tenantId(), item.id());
            } else {
                if (!"DEVICE_REPORTED_STORED".equals(state)) state = "DEVICE_REPORTED_RECEIVED";
                jdbc.update("UPDATE configuration_deliveries SET state=?,received_reported_at=COALESCE(received_reported_at,?) WHERE tenant_id=? AND id=?", state, now, identity.tenantId(), item.id());
            }
        }
        var accepted = new ReceiptAccepted(input.receiptId(), state, historical, "DEVICE_REPORT_NOT_EXECUTION", now);
        jdbc.update("INSERT INTO configuration_receipts(tenant_id,registration_id,id,delivery_id,request_hash,response_json,created_at) VALUES(?,?,?,?,?,?,?)",
            identity.tenantId(), identity.registrationId(), input.receiptId(), item.id(), requestHash, json(accepted), now);
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), historical ? "HISTORICAL_CONFIGURATION_RECEIPT" : "CONFIGURATION_RECEIPT_RECORDED", item.id());
        return accepted;
    }

    ItemPage<DeliveryView> list(String tenant, String actor, String publication, int limit, String cursor) {
        policies.publication(tenant, actor, publication); ItemPage.validate(limit, cursor);
        var rows = jdbc.query("SELECT d.*,s.delivery_id AS current_delivery_id FROM configuration_deliveries d LEFT JOIN configuration_streams s "
            + "ON s.tenant_id=d.tenant_id AND s.registration_id=d.registration_id AND s.policy_id=d.policy_id "
            + "WHERE d.tenant_id=? AND d.publication_id=? AND d.id>? ORDER BY d.id LIMIT ?", (row, index) -> {
                var item = map(row); boolean current = item.id().equals(row.getString("current_delivery_id"));
                String state = current && item.expiresAt() <= clock.millis() && item.storedAt() == null && !"DEVICE_REPORTED_REJECTED".equals(item.state())
                    ? "EXPIRED_AWAITING_PULL" : item.state();
                return new DeliveryView(item.id(), item.deviceId(), item.registration(), item.versionId(), item.sourceSequence(), item.cursor(), item.action(), state,
                    current, item.firstServedAt(), item.receivedAt(), item.storedAt(), item.rejection(), item.signingKeyId(), item.issuedAt(), item.expiresAt());
            }, tenant, publication, cursor == null ? "" : cursor, limit + 1);
        return ItemPage.from(rows, limit, DeliveryView::id);
    }
    private Delivery map(ResultSet row) throws SQLException {
        return new Delivery(row.getString("id"), row.getString("publication_id"), row.getString("version_id"), row.getString("policy_id"),
            row.getString("registration_id"), row.getString("device_id"), row.getLong("source_sequence"), row.getLong("device_cursor"), row.getString("action"),
            row.getString("document_json") == null ? null : read(row.getString("document_json"), ConfigurationDocument.class), row.getLong("issued_at"),
            row.getLong("delivery_expires_at"), row.getString("state"), row.getString("compact_jws"), row.getString("envelope_hash"), row.getString("signing_key_id"),
            number(row, "first_served_at"), number(row, "received_reported_at"), number(row, "stored_reported_at"), row.getString("rejection_code"));
    }
    private Long number(ResultSet row, String name) throws SQLException { var value = (Number) row.getObject(name); return value == null ? null : value.longValue(); }
    private String json(Object value) {
        try { return mapper.writer().with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Configuration serialization failed"); }
    }
    private <T> T read(String value, Class<T> type) {
        try { return mapper.readValue(value, type); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Configuration data unreadable"); }
    }
    record Pulled(String id, long cursor, String compactJws, long deliveryExpiresAt, String state) {
        @Override public String toString() { return "Pulled[id=" + id + ",cursor=" + cursor + "]"; }
    }
    record Pull(List<Pulled> items, long nextAfter, boolean hasMore, long serverTime) {}
    record ReceiptAccepted(String id, String state, boolean historical, String evidenceStatus, long receivedAt) {}
    record DeliveryView(String id, String deviceId, String registrationId, String versionId, long sourceSequence, long cursor, String action,
                        String state, boolean current, Long firstServedAt, Long receivedReportedAt, Long storedReportedAt, String rejectionCode,
                        String signingKeyId, long issuedAt, long deliveryExpiresAt) {}
    private record PreviousReceipt(String hash, String response) {}
    private record Delivery(String id, String publicationId, String versionId, String policyId, String registration, String deviceId,
                            long sourceSequence, long cursor, String action, ConfigurationDocument document, long issuedAt, long expiresAt,
                            String state, String compactJws, String envelopeHash, String signingKeyId, Long firstServedAt, Long receivedAt, Long storedAt, String rejection) {}
}
