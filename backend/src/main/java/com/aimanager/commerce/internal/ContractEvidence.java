package com.aimanager.commerce.internal;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.State;
import java.util.Set;

/**
 * Verified contract assertion from an independently configured procurement issuer. This record
 * contains no raw agreement, payment credential, child activity, or bearer token. Verification
 * alone never creates an entitlement; approval and customer acceptance are separate steps.
 */
record ContractEvidence(
    String eventId,
    String tenantId,
    String offerId,
    long offerRevision,
    String contractReference,
    long sourceRevision,
    String buyerReference,
    CapacityKind capacityKind,
    int deviceCapacity,
    Set<Feature> features,
    long activeFrom,
    long expiresAt,
    State state,
    long executedAt,
    String buyerSignatureReference,
    String sellerSignatureReference,
    String evidenceHash) {}
