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

    /** Explicit consumer policy; a verified SMS is recent authentication, never relabelled MFA. */
    public void requireForTenant(Jwt jwt,String tenant,org.springframework.jdbc.core.JdbcTemplate jdbc) {
        var kinds=jdbc.queryForList("SELECT kind FROM tenants WHERE id=?",String.class,tenant);
        if(kinds.size()!=1)throw DomainException.denied();
        if("FAMILY".equals(kinds.get(0))) {
            var time=jwt.getClaimAsInstant("auth_time");
            var methods=jwt.getClaimAsStringList("amr");
            var phone=jwt.getClaimAsString("phone_number");
            if(Boolean.TRUE.equals(jwt.getClaim("phone_number_verified")) && phone!=null && phone.matches("\\+861[3-9][0-9]{9}")
                && methods!=null && methods.contains("sms") && time!=null
                && !time.isBefore(clock.instant().minusSeconds(maxAge)) && !time.isAfter(clock.instant().plusSeconds(30)))return;
        }
        require(jwt);
    }
}
