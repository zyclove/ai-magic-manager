package com.aimanager.fleet;

/** Registration state and remote observation are separate from any system policy execution result. */
public record Device(String id, String subjectId, String registrationId, String displayName, Platform platform,
                     String osVersion, State state, String managementMode, String controlLevel,
                     Long lastHeartbeatAt, String observationStatus, String keyThumbprint, long version) {
    public enum Platform { ANDROID, ANDROID_TV }
    public enum Mode { BYOD, WORK_PROFILE, FULLY_MANAGED, DEDICATED }
    public enum State { AWAITING_CONFIRMATION, ACTIVE, REVOKED }
}
