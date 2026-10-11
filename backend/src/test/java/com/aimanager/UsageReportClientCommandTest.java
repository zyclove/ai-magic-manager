package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Path;
import org.junit.jupiter.api.Test;

class UsageReportClientCommandTest {
  @Test
  void nestedFlutterUsesPreparedDependenciesWithoutImplicitPubResolution() {
    var fixture = Path.of("report-fixture.json").toAbsolutePath();
    var output = Path.of("report-client.log").toAbsolutePath();
    var process = UsageReportJourneyTest.childReportProcess("flutter", fixture, output);

    assertThat(process.command())
        .containsExactly(
            "flutter", "test", "--no-pub", "tool/report_http_session_test.dart", "--concurrency=1");
    assertThat(process.environment()).containsEntry("CHILD_REPORT_HTTP_FIXTURE", fixture.toString());
    assertThat(process.redirectOutput().file()).isEqualTo(output.toFile());
    assertThat(process.redirectErrorStream()).isTrue();
    assertThat(process.directory())
        .isEqualTo(
            Path.of(System.getProperty("device.child.package", "../apps/child"))
                .toAbsolutePath()
                .toFile());
  }
}
