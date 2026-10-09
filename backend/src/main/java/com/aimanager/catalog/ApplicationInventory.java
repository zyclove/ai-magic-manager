package com.aimanager.catalog;

import java.util.List;

public record ApplicationInventory(String deviceId, String registrationId, long sequence, Long receivedAt,
                                    String visibility, String observationStatus, String evidenceStatus,
                                    List<ReportedApplication> applications) {}
