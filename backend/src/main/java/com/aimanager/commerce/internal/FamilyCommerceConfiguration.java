package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import com.aimanager.commerce.FamilyAssistedActivationGate;
import com.aimanager.commerce.FamilySalesGate;
import java.util.Map;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.core.env.Environment;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;

/** External integrations must replace these explicit unavailable boundaries before selling. */
@Configuration
class FamilyCommerceConfiguration {
  @Bean
  @ConditionalOnMissingBean(FamilyAssistedActivationGate.class)
  FamilyAssistedActivationGate familyAssistedActivationGate() {
    return (tenant, device) -> {
      throw new DomainException(HttpStatus.CONFLICT, "TRIAL_ACTIVATION_NOT_VERIFIED");
    };
  }

  @Bean
  @ConditionalOnMissingBean(FamilyPaymentGateway.class)
  FamilyPaymentGateway familyPaymentGateway(Environment environment, ObjectMapper json, Clock clock,FamilySalesGate salesGate) {
    var configured = FamilyWechatV3Gateway.configured(environment, json, clock,salesGate);
    if (configured != null) return configured;
    return new FamilyPaymentGateway() {
      @Override public boolean available() { return false; }
      @Override public AppPayment createAppPayment(PaymentCommand command) { throw unavailable(); }
      @Override public PaymentEvidence queryPayment(String id) { throw unavailable(); }
      @Override public Notification verifyNotification(Map<String, String> headers, String raw) { throw unavailable(); }
      @Override public void submitRefund(RefundCommand command) { throw unavailable(); }
      @Override public RefundEvidence queryRefund(String id) { throw unavailable(); }
    };
  }

  static DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "FAMILY_PAYMENT_UNAVAILABLE");
  }
}
