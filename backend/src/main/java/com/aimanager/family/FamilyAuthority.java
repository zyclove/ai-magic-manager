package com.aimanager.family;

import com.aimanager.tenant.TenantAccess;
import com.aimanager.shared.DomainException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
public class FamilyAuthority {
  private final TenantAccess access;
  private final JdbcTemplate jdbc;
  public FamilyAuthority(TenantAccess access,JdbcTemplate jdbc){this.access=access;this.jdbc=jdbc;}
  public void read(String tenant,String actor){access.requireRole(tenant,actor,OWNER,GUARDIAN);family(tenant);}
  public void write(String tenant,String actor){access.requireWriteRole(tenant,actor,OWNER,GUARDIAN);family(tenant);}
  private void family(String tenant){
    if(!"FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,tenant)))
      throw DomainException.denied();
  }
}
