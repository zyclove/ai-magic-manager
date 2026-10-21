package com.aimanager.notification.internal;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.*;
import org.springframework.core.env.Environment;

@Configuration
class FamilyPushConfiguration {
  @Bean
  @ConditionalOnMissingBean(FamilyPushGateway.class)
  FamilyPushGateway familyPushGateway(Environment environment,ObjectMapper json,Clock clock) {
    var configured=FamilyPushAliyunGateway.configured(environment,json,clock);
    if(configured!=null) return configured;
    return new FamilyPushGateway() {
      public boolean available(){return false;}
      public Accepted send(Command command){throw new Failure("PROVIDER_UNAVAILABLE",false);}
    };
  }
}
