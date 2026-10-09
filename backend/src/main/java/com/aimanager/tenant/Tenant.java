package com.aimanager.tenant;

public record Tenant(String id, String name, Kind kind, String timeZone, long version) {
    public enum Kind { FAMILY, ORGANIZATION }
}
