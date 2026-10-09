package com.aimanager.shared;

import java.util.Map;
import java.util.TreeMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

@RestControllerAdvice
class ApiErrorHandler {
  private static final Logger LOG = LoggerFactory.getLogger(ApiErrorHandler.class);

  private ProblemDetail problem(HttpStatus status, String code) {
    var detail = ProblemDetail.forStatus(status);
    detail.setProperty("errorCode", code);
    detail.setProperty("messageKey", "error." + code.toLowerCase(java.util.Locale.ROOT));
    detail.setProperty("correlationId", MDC.get("correlationId"));
    return detail;
  }

  @ExceptionHandler(DomainException.class)
  ProblemDetail domain(DomainException failure) {
    return problem(failure.status(), failure.errorCode());
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  ProblemDetail validation(MethodArgumentNotValidException failure) {
    var result = problem(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED");
    Map<String, String> fields = new TreeMap<>();
    failure
        .getBindingResult()
        .getFieldErrors()
        .forEach(error -> fields.put(error.getField(), error.getCode()));
    result.setProperty("fieldErrors", fields); // Do not echo rejected values or child text.
    return result;
  }

  @ExceptionHandler(
      org.springframework.web.method.annotation.HandlerMethodValidationException.class)
  ProblemDetail methodValidation(
      org.springframework.web.method.annotation.HandlerMethodValidationException failure) {
    // Spring MVC validates constrained query/path arguments separately from JSON bodies.
    return failure.isForReturnValue()
        ? problem(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR")
        : problem(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED");
  }

  @ExceptionHandler({
    HttpMessageNotReadableException.class,
    MethodArgumentTypeMismatchException.class,
    org.springframework.web.bind.MissingServletRequestParameterException.class
  })
  ProblemDetail malformed(Exception failure) {
    return problem(HttpStatus.BAD_REQUEST, "MALFORMED_REQUEST");
  }

  @ExceptionHandler(NoResourceFoundException.class)
  ProblemDetail notFound(NoResourceFoundException failure) {
    return problem(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND");
  }

  @ExceptionHandler(org.springframework.web.HttpRequestMethodNotSupportedException.class)
  org.springframework.http.ResponseEntity<ProblemDetail> methodNotAllowed(
      org.springframework.web.HttpRequestMethodNotSupportedException failure) {
    var methods = failure.getSupportedHttpMethods();
    return org.springframework.http.ResponseEntity.status(HttpStatus.METHOD_NOT_ALLOWED)
        .allow(
            methods == null
                ? new org.springframework.http.HttpMethod[0]
                : methods.toArray(org.springframework.http.HttpMethod[]::new))
        .body(problem(HttpStatus.METHOD_NOT_ALLOWED, "METHOD_NOT_ALLOWED"));
  }

  @ExceptionHandler(Exception.class)
  ProblemDetail unexpected(Exception failure) {
    // Exception messages may contain SQL values; log class and request ID only.
    LOG.error(
        "request failed exceptionType={} correlationId={}",
        failure.getClass().getName(),
        MDC.get("correlationId"));
    return problem(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR");
  }
}
