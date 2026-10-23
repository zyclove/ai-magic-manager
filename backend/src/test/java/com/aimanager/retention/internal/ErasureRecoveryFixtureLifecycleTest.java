package com.aimanager.retention.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertAll;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.verifyNoInteractions;

import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** Real, uniquely owned H2 resources; no Flyway, application context, or external database. */
class ErasureRecoveryFixtureLifecycleTest {
  @Test
  void closeReleasesEveryOwnedDatabase() throws Exception {
    var fixture = new ErasureRecoveryJobsTest();
    List<String> urls = new ArrayList<>();
    try {
      String first = owned(fixture, urls);
      String second = owned(fixture, urls);
      assertThat(first).isNotEqualTo(second);
      createSmallTable(first);
      createSmallTable(second);
      fixture.close();
      assertAll(
          () -> assertAbsent(first, "OWNED_H2_NORMAL_FIRST_RETAINED"),
          () -> assertAbsent(second, "OWNED_H2_NORMAL_SECOND_RETAINED"));
    } finally {
      removeOnlyOwnDatabases(urls);
    }
  }

  @Test
  void closeReleasesResourcesWhenInitializationFailsPartwayThrough() throws Exception {
    var fixture = new ErasureRecoveryJobsTest();
    List<String> urls = new ArrayList<>();
    try {
      String first = owned(fixture, urls);
      String second = owned(fixture, urls);
      assertThat(first).isNotEqualTo(second);
      createSmallTable(first);
      try {
        assertThrows(SQLException.class, () -> {
          try (var connection = DriverManager.getConnection(second, "sa", "");
              var statement = connection.createStatement()) {
            statement.executeQuery("SELECT * FROM fixture_table_that_does_not_exist");
          }
        });
      } finally {
        fixture.close();
      }
      assertAll(
          () -> assertAbsent(first, "OWNED_H2_FAILED_SETUP_FIRST_RETAINED"),
          () -> assertAbsent(second, "OWNED_H2_FAILED_SETUP_SECOND_RETAINED"));
    } finally {
      removeOnlyOwnDatabases(urls);
    }
  }

  @Test
  void closingTwiceDoesNotOpenAnyConnectionAgain() throws Exception {
    var fixture = new ErasureRecoveryJobsTest();
    List<String> urls = new ArrayList<>();
    try {
      createSmallTable(owned(fixture, urls));
      fixture.close();
      try (var connections = mockStatic(DriverManager.class)) {
        fixture.close();
        connections.verifyNoInteractions();
      }
    } finally {
      removeOnlyOwnDatabases(urls);
    }
  }

  @Test
  void externalOrReplacementDataSourcesAreNeverTouched() {
    var fixture = new ErasureRecoveryJobsTest();
    fixture.business = mock(DataSource.class);
    fixture.journal = mock(DataSource.class);
    fixture.close();
    fixture.close();
    verifyNoInteractions(fixture.business, fixture.journal);
  }

  private String owned(ErasureRecoveryJobsTest fixture, List<String> urls) {
    String prefix = "FIXTURE_LIFECYCLE_" + UUID.randomUUID().toString().replace("-", "");
    assertThat(System.getenv(prefix + "_URL")).isNull();
    var source = (DriverManagerDataSource) fixture.source(prefix);
    String url = source.getUrl();
    assertThat(url).matches("jdbc:h2:mem:[0-9a-f-]{36};MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
    urls.add(url);
    return url;
  }

  private void createSmallTable(String url) throws SQLException {
    try (var connection = DriverManager.getConnection(url, "sa", "");
        var statement = connection.createStatement()) {
      statement.execute("CREATE TABLE fixture_values(id INT PRIMARY KEY)");
      statement.execute("INSERT INTO fixture_values VALUES(1)");
    }
    try (var connection = DriverManager.getConnection(url + ";IFEXISTS=TRUE", "sa", "");
        var statement = connection.createStatement();
        var result = statement.executeQuery("SELECT COUNT(*) FROM fixture_values")) {
      assertThat(result.next()).isTrue();
      assertThat(result.getInt(1)).isEqualTo(1);
    }
  }

  private void assertAbsent(String url, String marker) throws SQLException {
    assertFalse(exists(url), marker);
  }

  private boolean exists(String url) throws SQLException {
    try (var ignored = DriverManager.getConnection(url + ";IFEXISTS=TRUE", "sa", "")) {
      return true;
    } catch (SQLException failure) {
      if (failure.getErrorCode() == 90146) return false;
      throw failure;
    }
  }

  private void removeOnlyOwnDatabases(List<String> urls) throws SQLException {
    SQLException failed = null;
    for (String url : urls) {
      assertThat(url).matches("jdbc:h2:mem:[0-9a-f-]{36};MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
      try (var connection = DriverManager.getConnection(url + ";IFEXISTS=TRUE", "sa", "");
          var statement = connection.createStatement()) {
        statement.execute("SHUTDOWN");
      } catch (SQLException failure) {
        if (failure.getErrorCode() != 90146) {
          if (failed == null) failed = failure;
          else failed.addSuppressed(failure);
        }
      }
    }
    if (failed != null) throw failed;
  }
}
