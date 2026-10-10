package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

/**
 * Activation must fail closed without qualifying and must not probe cloud credentials by default.
 */
class ManagedAndroidConfigurationTest {
  private final ApplicationContextRunner runner =
      new ApplicationContextRunner().withUserConfiguration(ManagedAndroidConfiguration.class);

  @Test
  void defaultUsesUnavailableProvider() {
    runner.run(
        context -> {
          assertThat(context).hasNotFailed();
          assertThat(context.getBean(ManagedAndroidGateway.class).available()).isFalse();
        });
  }

  @Test
  void enablingWithoutEligibilityFailsStartup() {
    runner
        .withPropertyValues("manager.emm.google.enabled=true")
        .run(context -> assertThat(context).hasFailed());
  }
}
