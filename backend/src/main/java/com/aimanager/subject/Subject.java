package com.aimanager.subject;

/** No exact birthday, identity document or photograph is collected by this aggregate. */
public record Subject(String id, String nickname, AgeBand ageBand, long version) {
    public enum AgeBand { UNDER_7, AGE_7_12, AGE_13_17 }
}
