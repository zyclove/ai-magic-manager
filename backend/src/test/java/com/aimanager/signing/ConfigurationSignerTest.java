package com.aimanager.signing;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.assertj.core.api.Assertions.*;

class ConfigurationSignerTest {
    @TempDir Path directory;
    private Path file(String name, String json) throws Exception { var path = directory.resolve(name); Files.writeString(path, json); return path; }
    @Test void noConfiguredKeyDoesNotGenerateAnEphemeralProductionKey() {
        var signer = new ConfigurationSigner("", "");
        assertThat(signer.configured()).isFalse();
        assertThatThrownBy(() -> signer.sign("{}" )).isInstanceOf(DomainException.class).extracting("errorCode").isEqualTo("SIGNING_KEY_NOT_CONFIGURED");
    }
    @Test void publicMaterialUsesVerifyOperationAndOldKeyRemainsDiscoverable() throws Exception {
        var active = new ECKeyGenerator(Curve.P_256).keyID("active").keyOperations(Set.of(KeyOperation.SIGN)).generate();
        var old = new ECKeyGenerator(Curve.P_256).keyID("old").generate();
        var signer = new ConfigurationSigner(file("active.jwk", active.toJSONString()).toString(),
            file("public.json", new JWKSet(List.of(old.toPublicJWK())).toString()).toString());
        var keys = JWKSet.parse(signer.publicKeys());
        assertThat(keys.getKeyByKeyId("active").isPrivate()).isFalse();
        assertThat(keys.getKeyByKeyId("active").getKeyOperations()).containsExactly(KeyOperation.VERIFY);
        assertThat(keys.getKeyByKeyId("old")).isNotNull();
    }
    @Test void privateVerificationRingWrongCurveAndDuplicateKidAreRejectedWithoutEchoingSecrets() throws Exception {
        var active = new ECKeyGenerator(Curve.P_256).keyID("same-kid").generate();
        String keyPath = file("active.jwk", active.toJSONString()).toString();
        String privateRing = file("private-ring.json", new JWKSet(active).toString(false)).toString();
        assertThatThrownBy(() -> new ConfigurationSigner(keyPath, privateRing)).isInstanceOf(IllegalArgumentException.class)
            .hasMessage("Invalid configuration signing key material").hasNoCause();
        var wrong = new ECKeyGenerator(Curve.P_384).keyID("wrong").generate();
        String wrongPath = file("wrong.jwk", wrong.toJSONString()).toString();
        assertThatThrownBy(() -> new ConfigurationSigner(wrongPath, "")).isInstanceOf(IllegalArgumentException.class);
        var duplicate = new ECKeyGenerator(Curve.P_256).keyID("same-kid").generate();
        String ring = file("duplicate.json", new JWKSet(duplicate.toPublicJWK()).toString()).toString();
        assertThatThrownBy(() -> new ConfigurationSigner(keyPath, ring)).isInstanceOf(IllegalArgumentException.class);
    }
    @Test void nimbusVerificationRejectsPayloadTampering() throws Exception {
        var key = new ECKeyGenerator(Curve.P_256).keyID("key").generate();
        var signer = new ConfigurationSigner(file("active.jwk", key.toJSONString()).toString(), "");
        String compact = signer.sign("{\"schemaVersion\":1}"); var original = JWSObject.parse(compact);
        assertThat(original.verify(new ECDSAVerifier(key.toPublicJWK()))).isTrue();
        var components = compact.split("\\.");
        String mutated = components[0] + "." + com.nimbusds.jose.util.Base64URL.encode("{\"schemaVersion\":2}") + "." + components[2];
        assertThat(JWSObject.parse(mutated).verify(new ECDSAVerifier(key.toPublicJWK()))).isFalse();
    }
}
