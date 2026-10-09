package com.aimanager.lifecycle;

import java.util.List;

/** A short-lived, actor-bound acknowledgement of the precise cloud and local consequences. */
public record DeprovisionPreview(String id, String deviceId, String registrationId, long deviceVersion,
                                  String action, List<String> consequences, List<String> limitations, String hash, long expiresAt) {}
