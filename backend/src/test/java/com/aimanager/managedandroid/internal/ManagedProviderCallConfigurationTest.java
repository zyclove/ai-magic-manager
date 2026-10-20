package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class ManagedProviderCallConfigurationTest {
  private final ApplicationContextRunner runner =
      new ApplicationContextRunner().withUserConfiguration(ManagedProviderCallConfiguration.class);

  @Test
  void defaultsCreateOneUsableExecutorAndCloseItWithTheContext() {
    var reference = new AtomicReference<ManagedProviderCalls>();
    runner.run(
        context -> {
          assertThat(context).hasNotFailed().hasSingleBean(ManagedProviderCalls.class);
          var calls = context.getBean(ManagedProviderCalls.class);
          reference.set(calls);
          assertThat(calls.call(calls.budget(Duration.ofSeconds(1)), () -> "ready"))
              .isEqualTo("ready");
          assertThat(calls.isClosed()).isFalse();
        });
    assertThat(reference.get().isClosed()).isTrue();
    assertThat(reference.get().isTerminated()).isTrue();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "manager.emm.provider-calls.workers=0",
        "manager.emm.provider-calls.workers=33",
        "manager.emm.provider-calls.budget-millis=0",
        "manager.emm.provider-calls.budget-millis=30001"
      })
  void invalidExecutorConfigurationFailsStartup(String property) {
    runner
        .withPropertyValues(property)
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasRootCauseInstanceOf(IllegalArgumentException.class);
            });
  }
}
