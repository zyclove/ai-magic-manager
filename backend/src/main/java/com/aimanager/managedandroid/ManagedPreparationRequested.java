package com.aimanager.managedandroid;

/** Transactional wake-up reference; durable request rows remain the source of business state. */
public record ManagedPreparationRequested(String tenantId, String requestId) {}
