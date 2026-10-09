package com.aimanager.fleet;

/** Internal authentication lookup; public registration keys confer no user or policy authority. */
public interface RegistrationKeys {
    Key key(String tenantId, String deviceId, String registrationId);
    record Key(String publicJwk, String thumbprint, Device.State state) {
        @Override public String toString() { return "RegistrationKey[state=" + state + "]"; }
    }
}
