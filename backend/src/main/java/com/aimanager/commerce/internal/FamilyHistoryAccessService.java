package com.aimanager.commerce.internal;

import com.aimanager.commerce.CommercialCapacity;
import com.aimanager.commerce.FamilyDeviceAccess;
import com.aimanager.commerce.FamilyHistoryAccess;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
class FamilyHistoryAccessService implements FamilyHistoryAccess {
  private static final ZoneId FAMILY_ZONE=ZoneId.of("Asia/Shanghai");
  private final FamilyDeviceAccess devices;
  private final CommercialCapacity capacity;
  private final JdbcTemplate db;
  private final Clock clock;
  FamilyHistoryAccessService(FamilyDeviceAccess devices,CommercialCapacity capacity,JdbcTemplate db,Clock clock) {
    this.devices=devices;this.capacity=capacity;this.db=db;this.clock=clock;
  }
  @Override public void lock(String tenant){devices.lockFamily(tenant);}
  @Override public void requireRange(String tenant,long from) {
    lock(tenant);
    if(!"FAMILY".equals(db.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,tenant)))return;
    // 日期边界固定为上海时区，不接受客户端用其他时区扩大免费历史范围。
    long today=Instant.ofEpochMilli(clock.millis()).atZone(FAMILY_ZONE).toLocalDate().atStartOfDay(FAMILY_ZONE).toInstant().toEpochMilli();
    if(from<today && capacity.currentForUpdate(tenant)==0)
      throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"ENTITLEMENT_REQUIRED");
  }
}
