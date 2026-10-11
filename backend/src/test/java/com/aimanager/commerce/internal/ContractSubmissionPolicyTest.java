package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.shared.DomainException;
import org.junit.jupiter.api.Test;

class ContractSubmissionPolicyTest {
  @Test
  void pausingNewContractsStillAllowsTrustedRevocationFacts() {
    var policy = new ContractSubmissionPolicy(true, false);
    assertThat(policy.activeAvailable()).isFalse();
    assertThat(policy.revocationAvailable()).isTrue();
    ContractEvidence active = mock(ContractEvidence.class);
    when(active.state()).thenReturn(State.ACTIVE);
    assertThatThrownBy(() -> policy.requireAllowed(active))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("CONTRACT_ACTIVE_SUBMISSIONS_PAUSED");
    ContractEvidence revoked = mock(ContractEvidence.class);
    when(revoked.state()).thenReturn(State.REVOKED);
    assertThatCode(() -> policy.requireAllowed(revoked)).doesNotThrowAnyException();
  }

  @Test
  void defaultWithoutIssuerHasNoAvailableSubmissionChannel() {
    var policy = new ContractSubmissionPolicy(false, false);
    assertThat(policy.activeAvailable()).isFalse();
    assertThat(policy.revocationAvailable()).isFalse();
    ContractEvidence active = mock(ContractEvidence.class);
    when(active.state()).thenReturn(State.ACTIVE);
    assertThatThrownBy(() -> policy.requireAllowed(active))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("CONTRACT_PROVIDER_UNAVAILABLE");
    ContractEvidence revoked = mock(ContractEvidence.class);
    when(revoked.state()).thenReturn(State.REVOKED);
    assertThatThrownBy(() -> policy.requireAllowed(revoked))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("CONTRACT_PROVIDER_UNAVAILABLE");
  }

  @Test
  void activeSwitchCannotOverrideDisabledIssuer() {
    var policy = new ContractSubmissionPolicy(false, true);
    assertThat(policy.activeAvailable()).isFalse();
    assertThatThrownBy(policy::requireActive)
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("CONTRACT_PROVIDER_UNAVAILABLE");
  }
}
