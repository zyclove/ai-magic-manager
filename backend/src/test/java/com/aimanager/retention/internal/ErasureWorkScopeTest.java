package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.aimanager.retention.ErasureLedger;
import java.util.concurrent.*;
import org.junit.jupiter.api.Test;

class ErasureWorkScopeTest {
  @Test
  void unconfiguredSourceDevelopmentDoesNotClaimToConsultTheLedger() {
    var ledger = mock(ErasureLedger.class);
    var scope = new ErasureWorkScope(ledger, false, "");
    try (var ignored = scope.enter()) {
      assertEquals(ErasureLedger.WorkState.READY, scope.state());
    }
    verifyNoInteractions(ledger);
  }

  @Test
  void configuredUrlEnforcesAdmissionEvenWithoutRequiredFlag() {
    var ledger = mock(ErasureLedger.class);
    var permit = mock(ErasureLedger.WorkPermit.class);
    when(ledger.beginWork(anyString())).thenReturn(permit);
    try (var ignored = new ErasureWorkScope(ledger, false, "jdbc:mysql:journal").enter()) {
      verify(ledger).beginWork(anyString());
    }
    verify(permit).close();
  }

  @Test
  void nestedSynchronousWorkHoldsOnePermitUntilEveryScopeHasExited() {
    var ledger = mock(ErasureLedger.class);
    var permit = mock(ErasureLedger.WorkPermit.class);
    when(ledger.beginWork(anyString())).thenReturn(permit);
    var scope = new ErasureWorkScope(ledger, true, "");
    var outer = scope.enter();
    var inner = scope.enter();
    verify(ledger).beginWork(anyString());
    outer.close();
    verifyNoInteractions(permit);
    inner.close();
    inner.close();
    verify(permit).close();
  }

  @Test
  void independentThreadsMustObtainTheirOwnPermit() throws Exception {
    var ledger = mock(ErasureLedger.class);
    when(ledger.beginWork(anyString())).thenAnswer(i -> mock(ErasureLedger.WorkPermit.class));
    var scope = new ErasureWorkScope(ledger, true, "");
    var pool = Executors.newSingleThreadExecutor();
    try (var ignored = scope.enter()) {
      pool.submit(
              () -> {
                try (var separate = scope.enter()) {}
              })
          .get(5, TimeUnit.SECONDS);
    } finally {
      pool.shutdownNow();
    }
    verify(ledger, times(2)).beginWork(anyString());
  }

  @Test
  void failedEntryAndFailedReleaseNeverLeaveAReusableThreadScope() {
    var ledger = mock(ErasureLedger.class);
    var first = mock(ErasureLedger.WorkPermit.class);
    var next = mock(ErasureLedger.WorkPermit.class);
    when(ledger.beginWork(anyString()))
        .thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"))
        .thenReturn(first, next);
    var scope = new ErasureWorkScope(ledger, true, "");
    assertThrows(ErasureLedger.Failure.class, scope::enter);
    doThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE")).when(first).close();
    var entered = scope.enter();
    assertThrows(ErasureLedger.Failure.class, entered::close);
    try (var ignored = scope.enter()) {}
    verify(next).close();
    verify(ledger, times(3)).beginWork(anyString());
  }

  @Test
  void readinessReflectsPersistedPauseAndFailures() {
    var ledger = mock(ErasureLedger.class);
    when(ledger.workState())
        .thenReturn(ErasureLedger.WorkState.PAUSING)
        .thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"));
    var scope = new ErasureWorkScope(ledger, true, "");
    assertEquals(ErasureLedger.WorkState.PAUSING, scope.state());
    assertThrows(ErasureLedger.Failure.class, scope::state);
  }
}
