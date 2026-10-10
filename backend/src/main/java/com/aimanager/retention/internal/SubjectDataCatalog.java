package com.aimanager.retention.internal;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.util.*;
import org.springframework.core.io.ClassPathResource;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Reviewed coverage inventory, not an erasure executor or a declaration of legal compliance. */
@Component
final class SubjectDataCatalog {
  enum Category {
    SUBJECT_DATA,
    DEVICE_DATA,
    DERIVED_COPY,
    AUTHORIZATION,
    AUDIT_RETENTION,
    SHARED_CONFIGURATION,
    SHARED_ACCOUNT,
    OPERATIONAL_METADATA
  }

  record Store(String table, List<String> columns, String domain, Category category) {}

  record Document(int version, List<Store> stores) {}

  record Group(Category category, int storeCount) {}

  record Coverage(int version, int storeCount, String sha256, List<Group> groups) {}

  private final JdbcTemplate db;
  private final SortedMap<String, SortedSet<String>> expected = new TreeMap<>();
  private final Coverage coverage;

  SubjectDataCatalog(JdbcTemplate db, ObjectMapper mapper) {
    this.db = db;
    try (var input = new ClassPathResource("retention/subject-data-stores.json").getInputStream()) {
      var document = mapper.readValue(input, Document.class);
      if (document.version() != 1
          || document.stores() == null
          || document.stores().isEmpty()
          || document.stores().size() > 500) throw new IllegalArgumentException();
      var groups = new EnumMap<Category, Integer>(Category.class);
      for (var store : document.stores()) {
        if (store.table() == null
            || !store.table().matches("[a-z][a-z0-9_]{0,63}")
            || store.domain() == null
            || !store.domain().matches("[a-z][a-z0-9]{0,63}")
            || store.category() == null
            || store.columns() == null
            || store.columns().isEmpty()
            || store.columns().size() > 200) throw new IllegalArgumentException();
        var columns = new TreeSet<String>();
        for (var column : store.columns()) {
          if (column == null || !column.matches("[a-z][a-z0-9_]{0,63}") || !columns.add(column))
            throw new IllegalArgumentException();
        }
        if (expected.putIfAbsent(store.table(), columns) != null)
          throw new IllegalArgumentException();
        groups.merge(store.category(), 1, Integer::sum);
      }
      // Bind the human-reviewed classification as well as the physical column names.
      var canonical = new StringBuilder("subject-data-catalog-v1\n");
      document.stores().stream()
          .sorted(Comparator.comparing(Store::table))
          .forEach(
              store ->
                  canonical
                      .append(store.table())
                      .append('|')
                      .append(store.domain())
                      .append('|')
                      .append(store.category())
                      .append('|')
                      .append(String.join(",", expected.get(store.table())))
                      .append('\n'));
      String hash =
          HexFormat.of()
              .formatHex(
                  MessageDigest.getInstance("SHA-256")
                      .digest(canonical.toString().getBytes(StandardCharsets.UTF_8)));
      coverage =
          new Coverage(
              document.version(),
              expected.size(),
              hash,
              groups.entrySet().stream().map(e -> new Group(e.getKey(), e.getValue())).toList());
    } catch (Exception invalid) {
      throw new IllegalStateException("Invalid subject data coverage catalogue", invalid);
    }
  }

  Coverage requireCurrentSchema() {
    final Map<String, SortedSet<String>> actual;
    try {
      actual = db.execute((ConnectionCallback<Map<String, SortedSet<String>>>) this::readSchema);
    } catch (org.springframework.dao.DataAccessException unavailable) {
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "ERASURE_SCHEMA_UNAVAILABLE");
    }
    if (!expected.equals(actual))
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "ERASURE_SCHEMA_REVIEW_REQUIRED");
    return coverage;
  }

  private Map<String, SortedSet<String>> readSchema(Connection connection)
      throws java.sql.SQLException {
    var actual = new TreeMap<String, SortedSet<String>>();
    var metadata = connection.getMetaData();
    String catalog = connection.getCatalog(), schema = connection.getSchema();
    try (var tables =
        metadata.getTables(catalog, schema, "%", new String[] {"TABLE", "BASE TABLE", "VIEW"})) {
      while (tables.next()) {
        String rawName = tables.getString("TABLE_NAME");
        String table = rawName.toLowerCase(Locale.ROOT);
        if (table.equals("flyway_schema_history")) continue;
        var columns = new TreeSet<String>();
        try (var rows = metadata.getColumns(catalog, schema, rawName, "%")) {
          while (rows.next()) columns.add(rows.getString("COLUMN_NAME").toLowerCase(Locale.ROOT));
        }
        if (actual.putIfAbsent(table, columns) != null || actual.size() > 500)
          throw new DomainException(
              HttpStatus.SERVICE_UNAVAILABLE, "ERASURE_SCHEMA_REVIEW_REQUIRED");
      }
    }
    return actual;
  }
}
