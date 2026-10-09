package com.aimanager.identity;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

/**
 * Exact OIDC subject storage key for the single configured issuer.
 * Database text collations must never alias differently cased subjects.
 * This digest is an index key, not an authentication credential. Multi-issuer
 * support must namespace this key with the verified issuer before enrollment.
 */
public final class ActorKeys {
    private ActorKeys() {}

    public static String key(String subject) {
        if (subject == null || subject.isBlank() || subject.length() > 255) {
            throw new IllegalArgumentException("Invalid verified subject");
        }
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(subject.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }
}
