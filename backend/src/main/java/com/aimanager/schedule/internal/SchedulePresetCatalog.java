package com.aimanager.schedule.internal;

import com.aimanager.schedule.ScheduleDefinition;
import com.aimanager.schedule.ScheduleDefinition.WeeklyWindow;
import com.aimanager.schedule.ScheduleEngine;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.Valid;
import jakarta.validation.Validator;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.io.IOException;
import java.util.HashSet;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Component;

/** Deployment-owned examples, validated once; never tenant schedules or active device rules. */
@Component
class SchedulePresetCatalog {
  private final Catalog catalog;

  SchedulePresetCatalog(
      @Value("${manager.schedule-presets.location:classpath:schedule-presets.json}") Resource resource,
      ObjectMapper mapper,
      Validator validator) {
    try (var input = resource.getInputStream()) {
      byte[] bytes = input.readNBytes(65_537);
      if (bytes.length > 65_536) throw new IllegalArgumentException("Schedule preset catalog too large");
      var parsed = mapper.readerFor(Catalog.class)
          .with(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
          .with(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .<Catalog>readValue(bytes);
      if (parsed == null || !validator.validate(parsed).isEmpty() || parsed.schemaVersion() != 1)
        throw new IllegalArgumentException("Invalid schedule preset catalog");
      var ids = new HashSet<String>();
      for (var preset : parsed.items()) {
        if (!ids.add(preset.id()) || unsafeText(preset.name()) || unsafeText(preset.description())
            || new HashSet<>(preset.weekly()).size() != preset.weekly().size())
          throw new IllegalArgumentException("Invalid or duplicate schedule preset");
        // Presets contain wall times only; the user's draft keeps its own IANA zone.
        ScheduleEngine.validate(new ScheduleDefinition("UTC", preset.weekly(), List.of()));
      }
      catalog = new Catalog(1, parsed.items().stream()
          .map(p -> new Preset(p.id(), p.name(), p.description(), List.copyOf(p.weekly())))
          .toList());
    } catch (IOException failure) {
      // Do not copy external resource contents into startup diagnostics.
      throw new IllegalStateException("Cannot read schedule preset catalog (" + failure.getClass().getSimpleName() + ")");
    }
  }

  private static boolean unsafeText(String text) {
    return !text.equals(text.strip())
        || text.codePoints().anyMatch(c -> Character.isISOControl(c) || Character.getType(c) == Character.FORMAT);
  }

  Catalog read() { return catalog; }

  record Catalog(int schemaVersion, @NotNull @Size(max = 20) List<@NotNull @Valid Preset> items) {}

  record Preset(
      @NotNull @Pattern(regexp = "[a-z][a-z0-9-]{0,39}") String id,
      @NotBlank @Size(max = 100) String name,
      @NotBlank @Size(max = 300) String description,
      @NotNull @Size(min = 1, max = 56) List<@NotNull @Valid WeeklyWindow> weekly) {}
}
