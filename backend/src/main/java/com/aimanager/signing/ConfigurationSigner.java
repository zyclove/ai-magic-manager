package com.aimanager.signing;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

/** Nimbus performs all JOSE/JCA operations. Production keys are external, never generated or journaled here. */
@Service
public class ConfigurationSigner {
    private final ECKey active;
    private final List<JWK> verificationKeys;
    public ConfigurationSigner(@Value("${manager.delivery.signing-key-file:}") String privateFile,
                               @Value("${manager.delivery.verification-keys-file:}") String verificationFile) {
        ECKey loaded = null;
        var publicKeys = new TreeMap<String, JWK>();
        try {
            if (!privateFile.isBlank()) {
                loaded = ECKey.parse(readBounded(privateFile, 8192));
                if (!loaded.isPrivate() || !Curve.P_256.equals(loaded.getCurve()) || !validId(loaded.getKeyID())
                    || (loaded.getAlgorithm() != null && !JWSAlgorithm.ES256.equals(loaded.getAlgorithm()))
                    || (loaded.getKeyUse() != null && !KeyUse.SIGNATURE.equals(loaded.getKeyUse()))
                    || (loaded.getKeyOperations() != null && !loaded.getKeyOperations().contains(KeyOperation.SIGN)))
                    throw new IllegalArgumentException();
                // Validate the key pair, not just the JWK's declared curve/type.
                var probe = new JWSObject(new JWSHeader(JWSAlgorithm.ES256), new Payload("key-pair-validation"));
                probe.sign(new ECDSASigner(loaded));
                if (!probe.verify(new com.nimbusds.jose.crypto.ECDSAVerifier(loaded.toPublicJWK()))) throw new IllegalArgumentException();
                publicKeys.put(loaded.getKeyID(), new ECKey.Builder(loaded.toPublicJWK()).algorithm(JWSAlgorithm.ES256)
                    .keyUse(KeyUse.SIGNATURE).keyOperations(Set.of(KeyOperation.VERIFY)).build());
            }
            if (!verificationFile.isBlank()) {
                var ring = JWKSet.parse(readBounded(verificationFile, 65536));
                if (ring.getKeys().size() > 32) throw new IllegalArgumentException();
                for (var candidate : ring.getKeys()) {
                    if (!(candidate instanceof ECKey key) || key.isPrivate() || !Curve.P_256.equals(key.getCurve()) || !validId(key.getKeyID())
                        || (key.getAlgorithm() != null && !JWSAlgorithm.ES256.equals(key.getAlgorithm()))
                        || (key.getKeyUse() != null && !KeyUse.SIGNATURE.equals(key.getKeyUse()))
                        || (key.getKeyOperations() != null && !key.getKeyOperations().contains(KeyOperation.VERIFY))) throw new IllegalArgumentException();
                    var previous = publicKeys.putIfAbsent(key.getKeyID(), key);
                    if (previous != null && !previous.computeThumbprint().equals(key.computeThumbprint())) throw new IllegalArgumentException();
                }
            }
        } catch (Exception failure) {
            // Parser messages/causes can echo private JWK fields. Never attach them to startup diagnostics.
            throw new IllegalArgumentException("Invalid configuration signing key material");
        }
        this.active = loaded; this.verificationKeys = List.copyOf(publicKeys.values());
    }
    private boolean validId(String kid) { return kid != null && kid.matches("[A-Za-z0-9_-]{1,64}"); }
    private String readBounded(String file, long maximum) throws Exception {
        Path path = Path.of(file);
        if (!Files.isRegularFile(path) || Files.size(path) > maximum) throw new IllegalArgumentException();
        return Files.readString(path);
    }
    public boolean configured() { return active != null; }
    public String activeKeyId() { return active == null ? null : active.getKeyID(); }
    public void requireConfigured() {
        if (active == null) throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "SIGNING_KEY_NOT_CONFIGURED");
    }
    public String sign(String encodedEnvelope) {
        return signTyped(encodedEnvelope, "aimanager-configuration+jws");
    }
    /** A distinct JOSE type and purpose prevent cleanup commands from being accepted as ordinary configuration. */
    public String signCleanup(String encodedCommand) {
        return signTyped(encodedCommand, "aimanager-cleanup-command+jws");
    }
    public String signQuotaLease(String encodedLease) {
        return signTyped(encodedLease, "aimanager-quota-lease+jws");
    }
    public String signAccessWindow(String encodedWindow) {
        return signTyped(encodedWindow, "aimanager-access-window+jws");
    }
    private String signTyped(String encodedEnvelope, String type) {
        requireConfigured();
        try {
            var message = new JWSObject(new JWSHeader.Builder(JWSAlgorithm.ES256)
                .type(new JOSEObjectType(type)).keyID(active.getKeyID()).build(), new Payload(encodedEnvelope));
            message.sign(new ECDSASigner(active));
            return message.serialize();
        } catch (JOSEException failure) { throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "SIGNING_TEMPORARILY_UNAVAILABLE"); }
    }
    /** Only public material; clients retrieve this over an authenticated TLS connection. */
    public Map<String, Object> publicKeys() { requireConfigured(); return new JWKSet(verificationKeys).toJSONObject(true); }
}
