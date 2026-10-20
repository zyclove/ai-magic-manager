package com.aimanager.managedandroid.internal;

import org.springframework.beans.factory.ListableBeanFactory;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.ConversionException;
import org.springframework.core.env.Environment;
import org.springframework.scheduling.annotation.AsyncAnnotationBeanPostProcessor;
import org.springframework.scheduling.annotation.ScheduledAnnotationBeanPostProcessor;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.scheduling.config.TaskManagementConfigUtils;

/**
 * Rejects incomplete local execution pipelines before this application accepts traffic. Durable
 * claims coordinate complete application replicas; an API-only host cannot infer that remote
 * workers exist from local flags. This checks wiring, never provider eligibility or device success.
 */
@Configuration(proxyBeanMethods = false)
class ManagedExecutionPipelineConfiguration {
  private static final String PREFIX = "manager.emm.execution.";

  @Bean
  SmartInitializingSingleton managedExecutionPipelineGuard(
      Environment environment, ListableBeanFactory beans) {
    var flags =
        new Flags(
            enabled(environment, "admission.enabled"),
            enabled(environment, "preparation.enabled"),
            enabled(environment, "preparation.recovery.enabled"),
            enabled(environment, "dispatch.enabled"),
            enabled(environment, "device-recovery.enabled"),
            enabled(environment, "manual-review.enabled"));
    flags.requireConsistent();
    if (flags.preparation())
      requireReadBudget(environment, "preparation", "preparation.lease-seconds", 60, 300);
    if (flags.dispatch()) requireReadBudget(environment, "dispatch", "lease-seconds", 30, 120);
    if (flags.observation())
      requireReadBudget(environment, "device-recovery", "lease-seconds", 30, 120);
    // Run after ordinary singleton construction, including conditional worker and infrastructure
    // beans. Default-off performs no consumer lookup, including no initialization of lazy beans.
    return () -> {
      if (flags.preparation()) {
        requireUnique(beans, ManagedPreparationWorker.class);
        requireUnique(beans, ManagedPreparationListener.class);
        requireNamed(beans, "managedPreparationExecutor", ThreadPoolTaskExecutor.class);
        requireNamed(
            beans,
            TaskManagementConfigUtils.ASYNC_ANNOTATION_PROCESSOR_BEAN_NAME,
            AsyncAnnotationBeanPostProcessor.class);
      }
      if (flags.recovery()) requireUnique(beans, ManagedPreparationRecoveryJob.class);
      if (flags.dispatch()) requireUnique(beans, ManagedExecutionDispatchJob.class);
      if (flags.observation()) requireUnique(beans, ManagedExecutionRecoveryJob.class);
      if (flags.recovery() || flags.dispatch() || flags.observation()) {
        requireNamed(
            beans,
            TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME,
            ScheduledAnnotationBeanPostProcessor.class);
      }
    };
  }

  private record Flags(
      boolean admission,
      boolean preparation,
      boolean recovery,
      boolean dispatch,
      boolean observation,
      boolean review) {
    void requireConsistent() {
      if (admission) {
        require(preparation, "admission requires preparation.enabled=true");
        require(recovery, "admission requires preparation.recovery.enabled=true");
        require(dispatch, "admission requires dispatch.enabled=true");
        require(observation, "admission requires device-recovery.enabled=true");
      }
      require(!recovery || preparation, "preparation recovery requires preparation.enabled=true");
      require(!dispatch || observation, "dispatch requires device-recovery.enabled=true");
      require(!review || observation, "manual review requires device-recovery.enabled=true");
      // Admission off is intentional during draining. Read-only observation and review need no
      // preparation/write consumer; they retain the original task expiry and authority checks.
    }
  }

  /** Fail at startup instead of consuming every durable attempt with a nonpositive I/O budget. */
  private static void requireReadBudget(
      Environment environment,
      String stage,
      String leaseProperty,
      long defaultLease,
      long maximumLease) {
    String reserveProperty = stage + ".commit-reserve-millis";
    long lease = number(environment, leaseProperty, defaultLease);
    long reserve = number(environment, reserveProperty, 10000);
    require(lease >= 5 && lease <= maximumLease, "invalid " + PREFIX + leaseProperty);
    require(reserve >= 1 && reserve <= 10000, "invalid " + PREFIX + reserveProperty);
    require(
        reserve < lease * 1000L,
        PREFIX
            + reserveProperty
            + " must be smaller than "
            + PREFIX
            + leaseProperty
            + " in milliseconds");
    // This proves positive configured time only. Queueing, authority checks and an approaching
    // task expiry still consume the absolute lease budget checked by each worker at runtime.
  }

  private static long number(Environment environment, String property, long fallback) {
    try {
      return environment.getProperty(PREFIX + property, Long.class, fallback);
    } catch (IllegalArgumentException | ConversionException invalid) {
      throw problem("invalid numeric property " + PREFIX + property);
    }
  }

  private static boolean enabled(Environment environment, String property) {
    try {
      return environment.getProperty(PREFIX + property, Boolean.class, false);
    } catch (IllegalArgumentException | ConversionException invalid) {
      // Do not include raw environment values or a nested exception that may contain them.
      throw problem("invalid boolean property " + PREFIX + property);
    }
  }

  private static void requireUnique(ListableBeanFactory beans, Class<?> type) {
    String[] names = beans.getBeanNamesForType(type, false, false);
    require(names.length == 1, "requires exactly one " + type.getSimpleName());
    beans.getBean(names[0], type);
  }

  private static void requireNamed(ListableBeanFactory beans, String name, Class<?> type) {
    require(
        beans.containsBean(name) && beans.isTypeMatch(name, type),
        "requires " + name + " of type " + type.getSimpleName());
    beans.getBean(name, type);
  }

  private static void require(boolean condition, String detail) {
    if (!condition) throw problem(detail);
  }

  private static IllegalStateException problem(String detail) {
    return new IllegalStateException("Managed execution configuration: " + detail);
  }
}
