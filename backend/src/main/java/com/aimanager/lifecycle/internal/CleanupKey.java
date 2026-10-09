package com.aimanager.lifecycle.internal;

import com.aimanager.fleet.RegistrationKeys;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.*;

/** The preview and cleanup authentication must accept exactly the same registered key metadata. */
final class CleanupKey {
    private CleanupKey() {}
    static ECKey read(RegistrationKeys.Key registered, String expectedThumbprint) throws Exception {
        var key = ECKey.parse(registered.publicJwk());
        if (key.isPrivate() || !Curve.P_256.equals(key.getCurve())
            || (key.getAlgorithm() != null && !JWSAlgorithm.ES256.equals(key.getAlgorithm()))
            || (key.getKeyUse() != null && !KeyUse.SIGNATURE.equals(key.getKeyUse()))
            || (key.getKeyOperations() != null && !key.getKeyOperations().contains(KeyOperation.VERIFY))
            || !key.computeThumbprint().toString().equals(registered.thumbprint()) || !registered.thumbprint().equals(expectedThumbprint))
            throw new IllegalArgumentException("Incompatible cleanup key");
        return key;
    }
}
