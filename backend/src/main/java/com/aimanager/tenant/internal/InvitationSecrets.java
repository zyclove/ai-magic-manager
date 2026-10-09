package com.aimanager.tenant.internal;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Locale;

/** Standard CSPRNG and SHA-256: raw invite secrets are returned once, never persisted or logged. */
final class InvitationSecrets {
    private static final SecureRandom RANDOM = new SecureRandom();
    private InvitationSecrets() {}

    static String issue() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    static String tokenHash(String token) { return hash("invite\0" + token); }
    static String emailHash(String email) {
        String trimmed = email.strip();
        int at = trimmed.lastIndexOf('@');
        // Only the domain is case-insensitive. Do not merge distinct case-sensitive local identities.
        String normalized = at >= 0 ? trimmed.substring(0, at) + trimmed.substring(at).toLowerCase(Locale.ROOT) : trimmed;
        return hash("email\0" + normalized);
    }

    private static String hash(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException unavailable) {
            throw new IllegalStateException("SHA-256 unavailable", unavailable);
        }
    }
}
