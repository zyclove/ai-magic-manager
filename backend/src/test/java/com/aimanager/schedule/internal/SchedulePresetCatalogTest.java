package com.aimanager.schedule.internal;

import static org.assertj.core.api.Assertions.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.Validation;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.ClassPathResource;

class SchedulePresetCatalogTest {
  private static final String ITEM = """
      {"id":"sample","name":"示例","description":"按实际安排调整",
       "weekly":[{"day":"MONDAY","start":"18:00","end":"20:00"}]}
      """;

  private SchedulePresetCatalog.Catalog read(String json) {
    try (var factory = Validation.buildDefaultValidatorFactory()) {
      return new SchedulePresetCatalog(new ByteArrayResource(json.getBytes(StandardCharsets.UTF_8)),
          new ObjectMapper().findAndRegisterModules(), factory.getValidator()).read();
    }
  }

  @Test void defaultCatalogIsValidatedAndImmutable() {
    try (var factory = Validation.buildDefaultValidatorFactory()) {
      var catalog = new SchedulePresetCatalog(new ClassPathResource("schedule-presets.json"),
          new ObjectMapper().findAndRegisterModules(), factory.getValidator()).read();
      assertThat(catalog.schemaVersion()).isEqualTo(1);
      assertThat(catalog.items()).hasSize(2);
      assertThat(catalog.items().get(0).weekly()).hasSize(5);
      assertThatThrownBy(() -> catalog.items().clear()).isInstanceOf(UnsupportedOperationException.class);
      assertThatThrownBy(() -> catalog.items().get(0).weekly().clear()).isInstanceOf(UnsupportedOperationException.class);
    }
  }

  @Test void emptyCatalogExplicitlyDisablesExamples() {
    assertThat(read("{\"schemaVersion\":1,\"items\":[]}").items()).isEmpty();
  }

  @Test void invalidCatalogsFailClosed() {
    for (var json : List.of(
        "{\"schemaVersion\":2,\"items\":[]}",
        "{\"schemaVersion\":1,\"items\":null}",
        "{\"schemaVersion\":1,\"items\":[null]}",
        "{\"schemaVersion\":1,\"items\":[],\"unknown\":true}",
        "{\"schemaVersion\":1,\"items\":[]} {}",
        "{\"schemaVersion\":1,\"items\":[" + ITEM + "," + ITEM + "]}",
        "{\"schemaVersion\":1,\"items\":[" + String.join(",", java.util.Collections.nCopies(21, ITEM)) + "]}",
        " ".repeat(65_537))) {
      assertThatThrownBy(() -> read(json)).isInstanceOf(RuntimeException.class);
    }
    for (var item : List.of(
        ITEM.replace("sample", "../bad"), ITEM.replace("示例", " 示例"),
        ITEM.replace("示例", "\\u202ehidden"), ITEM.replace("MONDAY", "INVALID"),
        ITEM.replace("18:00", "25:00"), ITEM.replace("20:00", "18:00"),
        ITEM.replace("\"day\":\"MONDAY\"", "\"day\":null"),
        ITEM.replace("\"weekly\":[{\"day\":\"MONDAY\",\"start\":\"18:00\",\"end\":\"20:00\"}]", "\"weekly\":[]"))) {
      assertThatThrownBy(() -> read("{\"schemaVersion\":1,\"items\":[" + item + "]}"))
          .isInstanceOf(RuntimeException.class);
    }
  }

  @Test void invalidExternalContentIsNotCopiedToDiagnostics() {
    assertThatThrownBy(() -> read("PRIVATE_CATALOG_CONTENT"))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("PRIVATE_CATALOG_CONTENT").hasNoCause();
  }
}
