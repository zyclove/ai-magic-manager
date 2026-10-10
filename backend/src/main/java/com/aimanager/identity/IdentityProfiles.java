package com.aimanager.identity;

import java.util.Collection;
import java.util.Map;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Display-only issuer evidence. Callers must authorize membership or the actor's own identity
 * before lookup.
 */
public interface IdentityProfiles {
  void observe(Jwt actor);

  Map<String, Profile> find(Collection<String> actorIds);

  record Profile(String actorId, String displayName, String verifiedEmail, long updatedAt) {}
}
