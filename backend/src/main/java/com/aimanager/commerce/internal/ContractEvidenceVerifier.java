package com.aimanager.commerce.internal;

/**
 * Replaceable trust boundary for a signed contract source. Implementations must verify the external
 * signature and all source assertions before returning normalized facts.
 */
interface ContractEvidenceVerifier {
  ContractEvidence verify(String compactJws);
}
