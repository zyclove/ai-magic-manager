import com.aimanager.delivery.ConfigurationDocument;
import com.aimanager.delivery.ConfigurationEnvelope;
import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** Test-only interoperability: actual backend records and signer, no production key. */
class NimbusConfigurationFixture {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Provide a new ignored output directory");
        Path directory = Path.of(args[0]).toAbsolutePath();
        Files.createDirectory(directory);
        Path privateKey = directory.resolve("temporary-signing-key.jwk");
        try {
            Files.writeString(privateKey, new ECKeyGenerator(Curve.P_256).keyID("nimbus-interop").generate().toJSONString());
            var signer = new ConfigurationSigner(privateKey.toString(), "");
            var document = new ConfigurationDocument("Nimbus \u4e92\u64cd\u4f5c\u5b66\u4e60\u8ba1\u5212", List.of(), List.of(), List.of(), List.of("com.example.emergency"));
            var envelope = new ConfigurationEnvelope(1,"ai-manager","CONFIGURATION","CONFIGURE_ONLY","UPSERT_CONFIGURATION",
                "11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222",
                "33333333-3333-4333-8333-333333333333","44444444-4444-4444-8444-444444444444",
                "55555555-5555-4555-8555-555555555555",1,1,"66666666-6666-4666-8666-666666666666",
                1791527999000L,1791528060000L,null,document);
            var mapper = new ObjectMapper();
            mapper.writeValue(directory.resolve("nimbus-fixture.json").toFile(), Map.of(
                "publicKeys", signer.publicKeys(), "compactJws", signer.sign(mapper.writeValueAsString(envelope))));
            System.out.println("Public interoperability fixture generated; temporary private key removed on exit.");
        } finally { Files.deleteIfExists(privateKey); }
    }
}
