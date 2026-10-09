package com.aimanager.identity;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;

/** Step-up uses signed IdP authentication facts, never a client boolean or local biometric result. */
@Service
public class RecentAuthentication {
    private final Clock clock;
    private final long maxAge;
    public RecentAuthentication(Clock clock, @Value("${manager.security.reauthentication-max-age-seconds:300}") long maxAge) {
        if (maxAge < 1 || maxAge > 900) throw new IllegalArgumentException("Recent-auth window must be between 1 and 900 seconds");
        this.clock = clock; this.maxAge = maxAge;
    }

    public void require(Jwt jwt) {
        Instant authenticated;
        List<String> methods;
        try {
            authenticated = jwt.getClaimAsInstant("auth_time");
            methods = jwt.getClaimAsStringList("amr");
        } catch (IllegalArgumentException failure) {
            throw new DomainException(HttpStatus.UNAUTHORIZED, "REAUTH_REQUIRED");
        }
        Instant now = clock.instant();
        boolean multiFactor = methods != null && (methods.contains("mfa") || (methods.contains("pwd") && methods.contains("otp")));
        if (authenticated == null || !multiFactor
                || authenticated.isBefore(now.minusSeconds(maxAge)) || authenticated.isAfter(now.plusSeconds(30))) {
            throw new DomainException(HttpStatus.UNAUTHORIZED, "REAUTH_REQUIRED");
        }
    }
}
