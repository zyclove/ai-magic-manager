package com.aimanager.fleet.internal;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jwt.SignedJWT;
import java.time.Clock;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Component;

/** Nimbus verifies ES256; this validator binds that proof to a short-lived enrollment purpose and nonce. */
@Component
class EnrollmentProof {
    private final Clock clock;
    EnrollmentProof(Clock clock) { this.clock = clock; }

    public Verified verify(String enrollment, String nonce, String publicKey, String serializedProof) {
        return verify(enrollment, nonce, publicKey, serializedProof, "ai-manager:enrollment-claim");
    }

    public Verified verify(String enrollment, String nonce, String publicKey, String serializedProof, String purpose) {
        try {
            var parsed = JWK.parse(publicKey);
            if (!(parsed instanceof ECKey key) || key.isPrivate() || !Curve.P_256.equals(key.getCurve())
                    || (key.getKeyUse() != null && !KeyUse.SIGNATURE.equals(key.getKeyUse()))) throw DomainException.denied();
            var proof = SignedJWT.parse(serializedProof);
            var header = proof.getHeader();
            if (!JWSAlgorithm.ES256.equals(header.getAlgorithm()) || !JOSEObjectType.JWT.equals(header.getType())
                    || header.getJWKURL() != null || header.getJWK() != null || header.getX509CertURL() != null
                    || header.getX509CertChain() != null || (header.getCriticalParams() != null && !header.getCriticalParams().isEmpty())
                    || !proof.verify(new ECDSAVerifier(key))) throw DomainException.denied();
            var claims = proof.getJWTClaimsSet();
            long now = clock.millis();
            if (!enrollment.equals(claims.getSubject()) || !List.of(purpose).equals(claims.getAudience())
                    || !nonce.equals(claims.getStringClaim("nonce")) || claims.getIssueTime() == null
                    || claims.getExpirationTime() == null || claims.getJWTID() == null) throw DomainException.denied();
            if (!UUID.fromString(claims.getJWTID()).toString().equals(claims.getJWTID())) throw DomainException.denied();
            long issued = claims.getIssueTime().getTime(), expires = claims.getExpirationTime().getTime();
            if (issued > now + 30_000 || issued < now - 120_000 || expires <= now || expires <= issued || expires > issued + 120_000
                    || (claims.getNotBeforeTime() != null && claims.getNotBeforeTime().getTime() > now + 30_000)) throw DomainException.denied();
            return new Verified(key.toPublicJWK().toJSONString(), key.computeThumbprint().toString(), claims.getJWTID());
        } catch (java.text.ParseException | JOSEException | IllegalArgumentException failure) {
            throw DomainException.denied();
        }
    }

    record Verified(String publicKeyJwk, String thumbprint, String proofId) {}
}
