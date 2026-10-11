package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.aimanager.retention.ErasureLedger;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;

class ErasureRuntimeWebTest {
  @Test
  void readinessDoesNotTreatPausedOrUnavailableLedgerAsReady() {
    var scope = mock(ErasureWorkScope.class);
    var readiness = new ErasureReadiness(scope);
    when(scope.state())
        .thenReturn(
            ErasureLedger.WorkState.READY,
            ErasureLedger.WorkState.PAUSING,
            ErasureLedger.WorkState.RECOVERY_REQUIRED)
        .thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"));
    assertEquals("UP", readiness.health().getStatus().getCode());
    for (int i = 0; i < 3; i++) {
      var health = readiness.health();
      assertEquals("DOWN", health.getStatus().getCode());
      assertTrue(health.getDetails().isEmpty());
    }
  }

  @Test
  void filterRegistrationForbidsAsynchronousEscapeAndRunsAfterAuthentication() {
    var registration =
        new ErasureRuntimeConfiguration()
            .erasureRuntimeFilter(mock(ErasureWorkScope.class), new ObjectMapper());
    assertFalse(registration.isAsyncSupported());
    assertEquals(
        org.springframework.boot.autoconfigure.security.SecurityProperties.DEFAULT_FILTER_ORDER
            + 10,
        registration.getOrder());
  }

  @Test
  void deniedAdmissionNeverInvokesTheBusinessChainAndReturnsSafeUncachedProblem() throws Exception {
    var scope = mock(ErasureWorkScope.class);
    when(scope.enter()).thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_IDENTITY_MISMATCH"));
    var response = new MockHttpServletResponse();
    var called = new AtomicInteger();
    new ErasureRuntimeFilter(scope, new ObjectMapper())
        .doFilter(
            new MockHttpServletRequest("GET", "/api/v1/tenants"),
            response,
            (q, s) -> called.incrementAndGet());
    assertEquals(0, called.get());
    assertEquals(503, response.getStatus());
    assertEquals("no-store", response.getHeader("Cache-Control"));
    assertEquals("30", response.getHeader("Retry-After"));
    assertEquals(
        "ERASURE_MAINTENANCE_REQUIRED",
        new ObjectMapper().readTree(response.getContentAsString()).path("errorCode").asText());
    assertFalse(response.getContentAsString().contains("IDENTITY_MISMATCH"));
  }

  @Test
  void onlyExactReadOnlyHealthRoutesBypassAdmission() throws Exception {
    var scope = mock(ErasureWorkScope.class);
    when(scope.enter()).thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"));
    var filter = new ErasureRuntimeFilter(scope, new ObjectMapper());
    for (String path :
        new String[] {
          "/actuator/health", "/actuator/health/liveness", "/actuator/health/readiness"
        }) {
      var response = new MockHttpServletResponse();
      filter.doFilter(
          new MockHttpServletRequest("GET", path),
          response,
          (q, s) -> s.getWriter().write("probe"));
      assertEquals("probe", response.getContentAsString());
    }
    verifyNoInteractions(scope);
    for (String path :
        new String[] {"/actuator/health/other", "/actuator/health-extra", "/api/v1/health"}) {
      var response = new MockHttpServletResponse();
      filter.doFilter(
          new MockHttpServletRequest("GET", path),
          response,
          (q, s) -> fail("Protected route bypassed"));
      assertEquals(503, response.getStatus());
    }
    var response = new MockHttpServletResponse();
    filter.doFilter(
        new MockHttpServletRequest("POST", "/actuator/health"),
        response,
        (q, s) -> fail("Write bypassed"));
    assertEquals(503, response.getStatus());
  }

  @Test
  void permitCoversTheWholeResponseAndIsReleasedOnFailure() throws Exception {
    var scope = mock(ErasureWorkScope.class);
    var permit = mock(ErasureLedger.WorkPermit.class);
    when(scope.enter()).thenReturn(permit);
    var filter = new ErasureRuntimeFilter(scope, new ObjectMapper());
    assertThrows(
        IOException.class,
        () ->
            filter.doFilter(
                new MockHttpServletRequest("GET", "/api/v1/data"),
                new MockHttpServletResponse(),
                (q, s) -> {
                  verifyNoInteractions(permit);
                  throw new IOException("fixture failure");
                }));
    verify(permit).close();
  }

  @Test
  void uncertainReleaseReplacesOnlyAnUncommittedResponse() throws Exception {
    var scope = mock(ErasureWorkScope.class);
    var permit = mock(ErasureLedger.WorkPermit.class);
    when(scope.enter()).thenReturn(permit);
    doThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE")).when(permit).close();
    var response = new MockHttpServletResponse();
    new ErasureRuntimeFilter(scope, new ObjectMapper())
        .doFilter(
            new MockHttpServletRequest("GET", "/api/v1/data"),
            response,
            (q, s) -> s.getWriter().write("private response"));
    assertEquals(503, response.getStatus());
    assertFalse(response.getContentAsString().contains("private response"));
    var committed = new MockHttpServletResponse();
    new ErasureRuntimeFilter(scope, new ObjectMapper())
        .doFilter(
            new MockHttpServletRequest("GET", "/api/v1/data"),
            committed,
            (q, s) -> {
              s.getWriter().write("already emitted");
              s.flushBuffer();
            });
    assertEquals("already emitted", committed.getContentAsString());
  }
}
