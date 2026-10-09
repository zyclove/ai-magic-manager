import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.lang.reflect.RecordComponent;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Test-only: constructs the actual backend private records, uses its Jackson
 * serializer and production signer with a temporary test key. No HTTP or device
 * execution is claimed by this fixture. */
class NimbusAccessFixture {
    private static final String PREFIX = "com.aimanager.approval.internal.AccessDeliveryService$";
    private static final long NOW = 1791528000000L;
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static Object record(String name, Map<String, Object> fields) throws Exception {
        Class<?> type = Class.forName(PREFIX + name);
        RecordComponent[] components = type.getRecordComponents();
        if (components == null || components.length != fields.size())
            throw new IllegalStateException("Backend record schema changed");
        Class<?>[] types = new Class<?>[components.length];
        Object[] arguments = new Object[components.length];
        for (int i = 0; i < components.length; i++) {
            if (!fields.containsKey(components[i].getName()))
                throw new IllegalStateException("Backend record schema changed");
            types[i] = components[i].getType();
            arguments[i] = fields.get(components[i].getName());
        }
        var constructor = type.getDeclaredConstructor(types);
        constructor.setAccessible(true);
        return constructor.newInstance(arguments);
    }
    private static Map<String, Object> envelope(boolean removal) {
        var fields = new LinkedHashMap<String, Object>();
        fields.put("schemaVersion", 1);
        fields.put("issuer", "ai-manager");
        fields.put("documentId", removal ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" : "66666666-6666-4666-8666-666666666666");
        fields.put("tenantId", "11111111-1111-4111-8111-111111111111");
        fields.put("requestId", "88888888-8888-4888-8888-888888888888");
        fields.put("approvalVersion", removal ? 2L : 1L);
        fields.put("approvalState", removal ? "REVOKED" : "APPROVED_PENDING_DELIVERY");
        fields.put("subjectId", "77777777-7777-4777-8777-777777777777");
        fields.put("deviceId", "22222222-2222-4222-8222-222222222222");
        fields.put("registrationId", "33333333-3333-4333-8333-333333333333");
        fields.put("policyId", "44444444-4444-4444-8444-444444444444");
        fields.put("baseVersionId", "55555555-5555-4555-8555-555555555555");
        fields.put("applicationId", "99999999-9999-4999-8999-999999999999");
        fields.put("ruleIds", List.of("game"));
        fields.put("action", removal ? "REMOVE_ACCESS_WINDOW" : "UPSERT_ACCESS_WINDOW");
        fields.put("mode", "CONFIGURE_ONLY");
        fields.put("quotaEffect", "UNCHANGED");
        fields.put("grantIssuedAt", NOW - 1000);
        fields.put("absoluteNotAfter", NOW + 299000);
        fields.put("documentIssuedAt", removal ? NOW + 500000 : NOW - 500);
        return fields;
    }
    private static Object document(Map<String, Object> envelope, String compact,
                                   int attempt) throws Exception {
        var fields = new LinkedHashMap<String, Object>();
        for (String key : List.of("documentId", "requestId", "approvalVersion", "action", "documentIssuedAt"))
            fields.put(key, envelope.get(key));
        fields.put("signedDocument", compact);
        fields.put("deliveryAttempt", attempt);
        fields.put("deliveryState", "SIGNED");
        fields.put("reasonCode", null);
        fields.put("retryStatus", "NOT_NEEDED");
        fields.put("retryAfter", null);
        return record("Document", fields);
    }
    private static Object acknowledgement(Map<String, Object> envelope, int attempt,
                                          String phase, boolean current) throws Exception {
        return record("Receipt", Map.of("documentId", envelope.get("documentId"),
            "approvalVersion", envelope.get("approvalVersion"), "phase", phase,
            "receivedAt", NOW, "current", current, "evidenceStatus", "DEVICE_REPORT_UNVERIFIED",
            "executionState", "NOT_ENFORCED", "deliveryAttempt", attempt));
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Provide a new ignored output directory");
        Path directory = Path.of(args[0]).toAbsolutePath();
        Files.createDirectory(directory);
        Path privateKey = directory.resolve("temporary-signing-key.jwk");
        try {
            Files.writeString(privateKey, new ECKeyGenerator(Curve.P_256).keyID("nimbus-access-interop").generate().toJSONString());
            var signer = new ConfigurationSigner(privateKey.toString(), "");
            var approved = envelope(false);
            var revoked = envelope(true);
            String compact = signer.signAccessWindow(MAPPER.writeValueAsString(record("Envelope", approved)));
            String removal = signer.signAccessWindow(MAPPER.writeValueAsString(record("Envelope", revoked)));
            MAPPER.writeValue(directory.resolve("nimbus-fixture.json").toFile(), Map.of(
                "publicKeys", signer.publicKeys(),
                "approved", document(approved, compact, 1),
                "retry", document(approved, compact, 2),
                "removed", document(revoked, removal, 1),
                "rejectionAck", acknowledgement(approved, 1, "REJECTED", false),
                "storedAck", acknowledgement(approved, 2, "STORED", true),
                "removalAck", acknowledgement(revoked, 1, "STORED", true)));
            System.out.println("Public fixture generated from actual approval records and signer.");
        } finally {
            Files.deleteIfExists(privateKey);
        }
    }
}
