package com.aimanager.shared;

import org.springframework.http.HttpStatus;

/** Strong single ETags only; wildcard/weak/multiple values cannot bypass lost-update checks. */
public final class ResourceVersions {
    private ResourceVersions() {}

    public static String tag(long version) { return "\"" + version + "\""; }

    public static long require(String ifMatch) {
        if (ifMatch == null) throw new DomainException(HttpStatus.PRECONDITION_REQUIRED, "VERSION_REQUIRED");
        if (!ifMatch.matches("\"(0|[1-9][0-9]{0,18})\"")) throw DomainException.invalid("INVALID_VERSION");
        try { return Long.parseLong(ifMatch.substring(1, ifMatch.length() - 1)); }
        catch (NumberFormatException failure) { throw DomainException.invalid("INVALID_VERSION"); }
    }

    public static void check(long expected, long actual) {
        if (expected != actual) throw new DomainException(HttpStatus.PRECONDITION_FAILED, "RESOURCE_VERSION_CONFLICT");
    }
}
