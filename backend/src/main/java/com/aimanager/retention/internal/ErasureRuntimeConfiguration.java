package com.aimanager.retention.internal;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.aop.Advisor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.*;

@Configuration(proxyBeanMethods = false)
class ErasureRuntimeConfiguration {
  @Bean
  @Role(BeanDefinition.ROLE_INFRASTRUCTURE)
  static Advisor erasureWorkAdvisor(ObjectProvider<ErasureWorkScope> scope) {
    return new ErasureWorkAdvisor(scope::getObject);
  }

  @Bean
  FilterRegistrationBean<ErasureRuntimeFilter> erasureRuntimeFilter(
      ErasureWorkScope scope, ObjectMapper json) {
    var registration = new FilterRegistrationBean<>(new ErasureRuntimeFilter(scope, json));
    registration.setOrder(
        org.springframework.boot.autoconfigure.security.SecurityProperties.DEFAULT_FILTER_ORDER
            + 10);
    registration.setAsyncSupported(false);
    return registration;
  }
}
