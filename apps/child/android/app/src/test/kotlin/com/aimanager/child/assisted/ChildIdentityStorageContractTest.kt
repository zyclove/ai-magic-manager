package com.aimanager.child.assisted

import com.it_nomads.fluttersecurestorage.ChildIdentityStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import org.junit.Assert.*
import org.junit.Test

class ChildIdentityStorageContractTest {
    @Test fun nativeReaderUsesTheExactFlutterV10CipherAndMigrationContract() {
        // AndroidOptions() v10 uses OAEP, while the Java SDK default is PKCS1.
        // Omitting this explicit option migrates back and forth across callers.
        val config = FlutterSecureStorageConfig(ChildIdentityStorage.options())
        assertEquals("RSA_ECB_OAEPwithSHA_256andMGF1Padding", config.prefOptionKeyCipherAlgorithm)
        assertEquals("AES_GCM_NoPadding", config.prefOptionStorageCipherAlgorithm)
        assertEquals("aimanager_identity_v1", config.sharedPreferencesName)
        assertEquals("aimanager", config.sharedPreferencesKeyPrefix)
        assertFalse(config.shouldDeleteOnFailure())
        assertTrue(config.shouldMigrateOnAlgorithmChange())
        assertFalse(config.enforceBiometrics)
    }
}
