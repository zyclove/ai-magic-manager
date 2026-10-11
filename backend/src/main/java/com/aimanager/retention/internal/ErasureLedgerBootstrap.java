package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import javax.sql.DataSource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;

/** Explicit offline setup. Not a Spring bean; never called by application startup or recovery. */
public final class ErasureLedgerBootstrap {
  private ErasureLedgerBootstrap() {}

  public static void initialize(DataSource source, String ledgerId) {
    new ErasureLedger.Checkpoint(ledgerId, 0, LedgerIntegrity.genesis(ledgerId));
    try (var connection = source.getConnection()) {
      var metadata = connection.getMetaData();
      try (var tables =
          metadata.getTables(
              connection.getCatalog(),
              connection.getSchema(),
              "%",
              new String[] {"TABLE", "BASE TABLE", "VIEW"})) {
        if (tables.next()) throw new ErasureLedger.Failure("ERASURE_LEDGER_NOT_EMPTY");
      }
    } catch (ErasureLedger.Failure failure) {
      throw failure;
    } catch (Exception unavailable) {
      throw new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE");
    }
    try {
      new ResourceDatabasePopulator(new ClassPathResource("erasure-ledger/initial-schema.sql"))
          .execute(source);
      new JdbcTemplate(source)
          .update(
              "INSERT INTO"
                  + " erasure_ledger_head(singleton_id,ledger_id,format_version,last_sequence,last_hash)"
                  + " VALUES(1,?,1,0,?)",
              ledgerId,
              LedgerIntegrity.genesis(ledgerId));
    } catch (Exception failure) {
      // A partial DDL failure stays closed and requires explicit operator handling; never drop
      // data.
      throw new ErasureLedger.Failure("ERASURE_LEDGER_INITIALIZATION_FAILED");
    }
  }

  public static void main(String[] args) {
    try {
      if (args.length != 1 || !args[0].equals("initialize-new-ledger"))
        throw new IllegalArgumentException();
      var env = System.getenv();
      String url = Objects.requireNonNull(env.get("ERASURE_LEDGER_URL"));
      if (!url.startsWith("jdbc:mysql:")) throw new IllegalArgumentException();
      initialize(
          new DriverManagerDataSource(
              url,
              Objects.requireNonNull(env.get("ERASURE_LEDGER_USERNAME")),
              Objects.requireNonNull(env.get("ERASURE_LEDGER_PASSWORD"))),
          Objects.requireNonNull(env.get("ERASURE_LEDGER_ID")));
      System.out.println(
          "Independent erasure ledger initialized. Preserve its identity and backups separately.");
    } catch (Exception failure) {
      System.err.println(
          failure instanceof ErasureLedger.Failure typed
              ? typed.code()
              : "ERASURE_LEDGER_INITIALIZATION_FAILED");
      System.exit(1);
    }
  }
}
