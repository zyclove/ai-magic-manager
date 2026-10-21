package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Thin access to the installed plugin, including its data-preserving migration.
 * No cipher, wrapping key, plaintext preferences or second identity record. */
public final class ChildIdentityStorage extends FlutterSecureStorage {
    private final Context context;
    private boolean ready;
    public static Map<String, Object> options() {
        return Map.of("sharedPreferencesName", "aimanager_identity_v1", "preferencesKeyPrefix", "aimanager",
            "resetOnError", "false", "migrateOnAlgorithmChange", "true",
            "keyCipherAlgorithm", "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
            "storageCipherAlgorithm", "AES_GCM_NoPadding", "enforceBiometrics", "false");
    }
    public ChildIdentityStorage(Context context) {
        super(context);
        this.context = context.getApplicationContext();
    }
    private void ensureReady() throws Exception {
        if (ready) return;
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Exception> failure = new AtomicReference<>();
        initialize(new FlutterSecureStorageConfig(options()), new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void unused) { done.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); done.countDown(); }
        });
        if (!done.await(20, TimeUnit.SECONDS) || failure.get() != null) {
            throw new IllegalStateException("SECURE_STORAGE_FAILED");
        }
        flush();
        ready = true;
    }
    public String readIdentity() throws Exception {
        ensureReady();
        String value = read(addPrefixToKey("identity_record"));
        flush();
        if (value != null && value.length() > 65536) throw new IllegalStateException("SECURE_STORAGE_FAILED");
        return value;
    }
    public void writeIdentity(String value) throws Exception {
        ensureReady();
        if (value == null) delete(addPrefixToKey("identity_record"));
        else write(addPrefixToKey("identity_record"), value);
        flush();
        if (!java.util.Objects.equals(readIdentity(), value)) throw new IllegalStateException("SECURE_STORAGE_FAILED");
    }
    public String readObservation() throws Exception {
        ensureReady();
        String value = read(addPrefixToKey("observation_record"));
        flush();
        if (value != null && value.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1048576) {
            throw new IllegalStateException("SECURE_STORAGE_FAILED");
        }
        return value;
    }
    public void writeObservation(String value) throws Exception {
        ensureReady();
        if (value == null) delete(addPrefixToKey("observation_record"));
        else {
            if (value.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1048576) {
                throw new IllegalStateException("SECURE_STORAGE_FAILED");
            }
            write(addPrefixToKey("observation_record"), value);
        }
        flush();
        if (!java.util.Objects.equals(readObservation(), value)) throw new IllegalStateException("SECURE_STORAGE_FAILED");
    }
    public void flush() {
        for (String name : new String[]{"FlutterSecureKeyStorage", "FlutterSecureStorageConfiguration", "aimanager_identity_v1"}) {
            if (!context.getSharedPreferences(name, Context.MODE_PRIVATE).edit()
                    .putString("__durability_barrier", UUID.randomUUID().toString()).commit()) {
                throw new IllegalStateException("SECURE_STORAGE_FAILED");
            }
        }
    }
}
