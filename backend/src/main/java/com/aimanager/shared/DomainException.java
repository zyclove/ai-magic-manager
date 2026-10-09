package com.aimanager.shared;

import org.springframework.http.HttpStatus;

/** Stable public code; never include SQL, credentials or another tenant's details in errors. */
public final class DomainException extends RuntimeException {
    private final HttpStatus status;
    private final String errorCode;

    public DomainException(HttpStatus status, String errorCode) {
        super(errorCode);
        this.status = status;
        this.errorCode = errorCode;
    }

    public HttpStatus status() { return status; }
    public String errorCode() { return errorCode; }
    public static DomainException denied() { return new DomainException(HttpStatus.FORBIDDEN, "SCOPE_DENIED"); }
    public static DomainException invalid(String code) { return new DomainException(HttpStatus.BAD_REQUEST, code); }
}
