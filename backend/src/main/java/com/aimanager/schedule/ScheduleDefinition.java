package com.aimanager.schedule;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.util.List;

/** Allow windows use local calendar dates in an IANA zone, with exclusive ends. */
public record ScheduleDefinition(@NotBlank @Size(max = 100) String timeZone,
                                 @NotNull @Size(max = 56) List<@NotNull @Valid WeeklyWindow> weekly,
                                 @NotNull @Size(max = 366) List<@NotNull @Valid DateOverride> exceptions) {
    public record WeeklyWindow(@NotNull DayOfWeek day,
                               @NotNull @Pattern(regexp = "([01][0-9]|2[0-3]):[0-5][0-9]") String start,
                               @NotNull @Pattern(regexp = "([01][0-9]|2[0-3]):[0-5][0-9]") String end) {}
    public record Window(@NotNull @Pattern(regexp = "([01][0-9]|2[0-3]):[0-5][0-9]") String start,
                         @NotNull @Pattern(regexp = "([01][0-9]|2[0-3]):[0-5][0-9]") String end) {}
    /** An empty override closes that entire date, including carryover from the previous night. */
    public record DateOverride(@NotNull LocalDate date, @NotNull @Size(max = 8) List<@NotNull @Valid Window> windows) {}
}
