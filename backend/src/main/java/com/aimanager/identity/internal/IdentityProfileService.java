package com.aimanager.identity.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.IdentityProfiles;
import jakarta.validation.Validator;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.Size;
import java.time.Clock;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class IdentityProfileService implements IdentityProfiles {
  private final JdbcTemplate jdbc;
  private final Clock clock;
  private final Validator validator;

  IdentityProfileService(JdbcTemplate jdbc, Clock clock, Validator validator) {
    this.jdbc = jdbc;
    this.clock = clock;
    this.validator = validator;
  }

  @Override
  @Transactional(timeout = 10)
  public void observe(Jwt actor) {
    var issued = actor.getIssuedAt();
    // Missing/unusable issue time never lets an older assertion overwrite newer display evidence.
    if (issued == null
        || issued.toEpochMilli() < 0
        || issued.isAfter(clock.instant().plusSeconds(30))) return;
    String name = display(actor.getClaims().get("name"));
    String email =
        Boolean.TRUE.equals(actor.getClaims().get("email_verified"))
            ? email(actor.getClaims().get("email"))
            : null;
    String actorId = actor.getSubject(), key = ActorKeys.key(actorId);
    long now = clock.millis();
    try {
      jdbc.update(
          "INSERT INTO"
              + " actor_profiles(actor_key,actor_id,display_name,verified_email,claims_issued_at,observed_at)"
              + " VALUES(?,?,?,?,?,?)",
          key,
          actorId,
          name,
          email,
          issued.toEpochMilli(),
          now);
    } catch (DuplicateKeyException exists) {
      Long previous =
          jdbc.queryForObject(
              "SELECT claims_issued_at FROM actor_profiles WHERE actor_key=? FOR UPDATE",
              Long.class,
              key);
      if (previous != null && issued.toEpochMilli() > previous)
        jdbc.update(
            "UPDATE actor_profiles SET"
                + " display_name=?,verified_email=?,claims_issued_at=?,observed_at=? WHERE"
                + " actor_key=?",
            name,
            email,
            issued.toEpochMilli(),
            now,
            key);
    }
  }

  @Override
  @Transactional(readOnly = true)
  public Map<String, Profile> find(Collection<String> actorIds) {
    if (actorIds.size() > 100)
      throw new IllegalArgumentException("Profile lookup must be a bounded authorized member page");
    if (actorIds.isEmpty()) return Map.of();
    var keys = actorIds.stream().map(ActorKeys::key).distinct().toList();
    String slots = String.join(",", java.util.Collections.nCopies(keys.size(), "?"));
    var rows =
        jdbc.query(
            "SELECT actor_id,display_name,verified_email,observed_at FROM actor_profiles WHERE"
                + " actor_key IN ("
                + slots
                + ")",
            (r, n) -> new Profile(r.getString(1), r.getString(2), r.getString(3), r.getLong(4)),
            keys.toArray());
    var result = new HashMap<String, Profile>();
    for (var row : rows) result.put(row.actorId(), row);
    return Map.copyOf(result);
  }

  private String display(Object raw) {
    if (!(raw instanceof String value)) return null;
    String name = value.replaceAll("[\\p{Cntrl}]", "").strip();
    if (name.isEmpty()) return null;
    int end = Math.min(name.length(), 100);
    if (Character.isHighSurrogate(name.charAt(end - 1))) end--;
    return name.substring(0, end);
  }

  private String email(Object raw) {
    if (!(raw instanceof String value)) return null;
    String email = value.strip();
    if (email.isEmpty() || !validator.validate(new EmailValue(email)).isEmpty()) return null;
    return email;
  }

  private record EmailValue(@Email @Size(max = 254) String email) {}
}
