package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.FilterType;
import org.springframework.scheduling.annotation.AsyncAnnotationBeanPostProcessor;
import org.springframework.scheduling.annotation.ScheduledAnnotationBeanPostProcessor;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.scheduling.config.TaskManagementConfigUtils;

/** Startup topology only: worker/infrastructure beans are explicit inert fixtures, no SDK calls. */
class ManagedExecutionPipelineConfigurationTest {
  private static final String PREFIX = "manager.emm.execution.";
  private static final String ASYNC =
      TaskManagementConfigUtils.ASYNC_ANNOTATION_PROCESSOR_BEAN_NAME;
  private static final String SCHEDULER =
      TaskManagementConfigUtils.SCHEDULED_ANNOTATION_PROCESSOR_BEAN_NAME;

  @Configuration(proxyBeanMethods = false)
  @ComponentScan(
      basePackageClasses = ManagedPreparationAdmission.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.REGEX,
              pattern =
                  "com\\.aimanager\\.managedandroid\\.internal\\.ManagedExecutionPipelineConfiguration"))
  static class Scan {}

  private ApplicationContextRunner runner() {
    return new ApplicationContextRunner().withUserConfiguration(Scan.class);
  }

  private ApplicationContextRunner flags(
      ApplicationContextRunner runner,
      boolean admission,
      boolean preparation,
      boolean recovery,
      boolean dispatch,
      boolean observation,
      boolean review) {
    return runner.withPropertyValues(
        PREFIX + "admission.enabled=" + admission,
        PREFIX + "preparation.enabled=" + preparation,
        PREFIX + "preparation.recovery.enabled=" + recovery,
        PREFIX + "dispatch.enabled=" + dispatch,
        PREFIX + "device-recovery.enabled=" + observation,
        PREFIX + "manual-review.enabled=" + review);
  }

  private <T extends BeanPostProcessor> T inertProcessor(Class<T> type) {
    T processor = mock(type);
    when(processor.postProcessBeforeInitialization(any(), anyString()))
        .thenAnswer(call -> call.getArgument(0));
    when(processor.postProcessAfterInitialization(any(), anyString()))
        .thenAnswer(call -> call.getArgument(0));
    return processor;
  }

  private ApplicationContextRunner workers(ApplicationContextRunner r, Set<String> omitted) {
    if (!omitted.contains("listener"))
      r =
          r.withBean(
              ManagedPreparationListener.class, () -> mock(ManagedPreparationListener.class));
    if (!omitted.contains("worker"))
      r = r.withBean(ManagedPreparationWorker.class, () -> mock(ManagedPreparationWorker.class));
    if (!omitted.contains("recovery"))
      r =
          r.withBean(
              ManagedPreparationRecoveryJob.class, () -> mock(ManagedPreparationRecoveryJob.class));
    if (!omitted.contains("dispatch"))
      r =
          r.withBean(
              ManagedExecutionDispatchJob.class, () -> mock(ManagedExecutionDispatchJob.class));
    if (!omitted.contains("observation"))
      r =
          r.withBean(
              ManagedExecutionRecoveryJob.class, () -> mock(ManagedExecutionRecoveryJob.class));
    if (!omitted.contains("executor"))
      r =
          r.withBean(
              "managedPreparationExecutor",
              ThreadPoolTaskExecutor.class,
              () -> mock(ThreadPoolTaskExecutor.class));
    if (!omitted.contains("async"))
      r =
          r.withBean(
              ASYNC,
              AsyncAnnotationBeanPostProcessor.class,
              () -> inertProcessor(AsyncAnnotationBeanPostProcessor.class));
    if (!omitted.contains("scheduler"))
      r =
          r.withBean(
              SCHEDULER,
              ScheduledAnnotationBeanPostProcessor.class,
              () -> inertProcessor(ScheduledAnnotationBeanPostProcessor.class));
    return r;
  }

  private ApplicationContextRunner full() {
    return flags(workers(runner(), Set.of()), true, true, true, true, true, false);
  }

  private void starts(ApplicationContextRunner r) {
    r.run(context -> assertThat(context).hasNotFailed());
  }

  private void rejects(ApplicationContextRunner r, String reason) {
    r.run(
        context -> {
          assertThat(context).hasFailed();
          assertThat(context.getStartupFailure()).hasStackTraceContaining(reason);
        });
  }

  @ParameterizedTest
  @org.junit.jupiter.params.provider.CsvSource({
    "preparation,preparation.lease-seconds,5,10000",
    "preparation,preparation.lease-seconds,10,10000",
    "dispatch,lease-seconds,5,10000",
    "dispatch,lease-seconds,10,10000",
    "device-recovery,lease-seconds,5,10000",
    "device-recovery,lease-seconds,10,10000"
  })
  void enabledStageNeedsPositiveProviderTime(String stage, String lease, int seconds, int reserve) {
    rejects(
        full()
            .withPropertyValues(
                PREFIX + "preparation.commit-reserve-millis=1000",
                PREFIX + "dispatch.commit-reserve-millis=1000",
                PREFIX + "device-recovery.commit-reserve-millis=1000",
                PREFIX + lease + "=" + seconds,
                PREFIX + stage + ".commit-reserve-millis=" + reserve),
        stage + ".commit-reserve-millis");
  }

  @Test
  void shortLeaseWithSmallerReservesIsValid() {
    starts(
        full()
            .withPropertyValues(
                PREFIX + "lease-seconds=5",
                PREFIX + "preparation.lease-seconds=5",
                PREFIX + "preparation.commit-reserve-millis=1000",
                PREFIX + "dispatch.commit-reserve-millis=1000",
                PREFIX + "device-recovery.commit-reserve-millis=1000"));
  }

  @Test
  void inactiveStagesDoNotBlockAnObservationOnlyHost() {
    starts(
        flags(workers(runner(), Set.of()), false, false, false, false, true, false)
            .withPropertyValues(PREFIX + "preparation.lease-seconds=5"));
  }

  @Test
  void defaultsAllowNormalNonManagedApplicationStartup() {
    starts(runner());
  }

  @Test
  void completePipelineCanAcceptNewPublications() {
    starts(full());
  }

  @Test
  void completePipelineCanAlsoOfferManualReview() {
    starts(full().withPropertyValues(PREFIX + "manual-review.enabled=true"));
  }

  @Test
  void admissionCanStopWhileAllWorkersDrain() {
    starts(full().withPropertyValues(PREFIX + "admission.enabled=false"));
  }

  @Test
  void observationCanRunWithoutAnyNewWrites() {
    starts(flags(workers(runner(), Set.of()), false, false, false, false, true, false));
  }

  @Test
  void manualReviewNeedsNoWriteConsumer() {
    starts(flags(workers(runner(), Set.of()), false, false, false, false, true, true));
  }

  @Test
  void defaultsDoNotInstantiateLazyWorkers() {
    var calls = new AtomicInteger();
    runner()
        .withBean(
            ManagedPreparationWorker.class,
            () -> {
              calls.incrementAndGet();
              throw new IllegalStateException("Lazy worker must not be touched");
            },
            definition -> definition.setLazyInit(true))
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              assertThat(calls).hasValue(0);
            });
  }

  @Test
  void invalidBooleanDoesNotSilentlyDisableProtection() {
    rejects(runner().withPropertyValues(PREFIX + "admission.enabled=enabled"), "admission.enabled");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "preparation.enabled",
        "preparation.recovery.enabled",
        "dispatch.enabled",
        "device-recovery.enabled"
      })
  void admissionRequiresEveryDownstreamStage(String property) {
    rejects(
        full().withPropertyValues(PREFIX + property + "=false"),
        "Managed execution configuration:");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {"preparation.recovery.enabled", "dispatch.enabled", "manual-review.enabled"})
  void dependentStageCannotBeEnabledOnItsOwn(String property) {
    rejects(
        workers(runner(), Set.of()).withPropertyValues(PREFIX + property + "=true"),
        "Managed execution configuration:");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "listener",
        "worker",
        "recovery",
        "dispatch",
        "observation",
        "executor",
        "async",
        "scheduler"
      })
  void enabledFlagsDoNotReplaceActualBeans(String missing) {
    rejects(
        flags(workers(runner(), Set.of(missing)), true, true, true, true, true, false),
        "Managed execution configuration:");
  }

  @Test
  void unrelatedExecutorCannotMasqueradeAsPreparationPool() {
    rejects(
        flags(
            workers(runner(), Set.of("executor"))
                .withBean("managedPreparationExecutor", Object.class, Object::new),
            true,
            true,
            true,
            true,
            true,
            false),
        "Managed execution configuration:");
  }
}
