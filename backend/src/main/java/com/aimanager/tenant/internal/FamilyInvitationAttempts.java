package com.aimanager.tenant.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Independent transaction: a rejected secret/phone must still consume an attempt on every replica. */
@Service
class FamilyInvitationAttempts {
  private static final long WINDOW=600_000;
  private final JdbcTemplate db;
  private final Clock clock;
  FamilyInvitationAttempts(JdbcTemplate db,Clock clock) { this.db=db;this.clock=clock; }
  @Transactional(propagation=Propagation.REQUIRES_NEW,timeout=5)
  public void require(String actor) {
    String key=ActorKeys.key(actor);long now=clock.millis();
    db.update("INSERT INTO family_invitation_attempts(actor_key,window_start,attempts) VALUES(?,?,0) ON DUPLICATE KEY UPDATE actor_key=actor_key",key,now);
    var row=db.queryForMap("SELECT window_start,attempts FROM family_invitation_attempts WHERE actor_key=? FOR UPDATE",key);
    long start=((Number)row.get("window_start")).longValue();int count=((Number)row.get("attempts")).intValue();
    if(now<start || now-start>=WINDOW) { start=now;count=0; }
    if(count>=30)throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,"FAMILY_INVITATION_RATE_LIMITED");
    db.update("UPDATE family_invitation_attempts SET window_start=?,attempts=? WHERE actor_key=?",start,count+1,key);
  }
  @Scheduled(fixedDelayString="${manager.family.invitation-attempt-cleanup-ms:3600000}")
  @Transactional(timeout=10)
  public void clean() {
    db.update("DELETE FROM family_invitation_attempts WHERE window_start<?",clock.millis()-86_400_000);
  }
}
