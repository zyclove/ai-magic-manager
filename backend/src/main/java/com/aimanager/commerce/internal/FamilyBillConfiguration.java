package com.aimanager.commerce.internal;

import java.time.LocalDate;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
class FamilyBillConfiguration {
  @Bean
  @ConditionalOnMissingBean(FamilyBillGateway.class)
  FamilyBillGateway familyBillGateway(FamilyPaymentGateway payment) {
    if (payment instanceof FamilyWechatV3Gateway configured) return new FamilyWechatBillGateway(configured);
    return new FamilyBillGateway() {
      @Override public boolean available() { return false; }
      @Override public String merchantId() { return "UNCONFIGURED"; }
      @Override public String appId() { return "UNCONFIGURED"; }
      @Override public BillFile download(LocalDate day) { throw new Unavailable("BILL_PROVIDER_UNAVAILABLE"); }
    };
  }
}
