-- Supports bounded provider-specific expiry scans without walking unrelated intents.
CREATE INDEX ix_managed_intent_provider_expiry
    ON managed_enrollment_intents(provider, state, expires_at, id);
