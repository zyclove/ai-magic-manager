# Device cleanup command verification

This package verifies the server's limited `AGENT_CLEANUP` command. It cannot
unenroll an Android device, wipe storage, stop another app, or delete local
records. The command permits only this application's own policy cache, usage
cache and ordinary business credential to be cleared. The original key must
remain available until the server acknowledges the cleanup receipt.

## Composition boundary

```dart
final identityView = await identity.view();
final proof = await identity.cleanupProof(action: 'READ');
// A separate cleanup transport must use the configured authenticated TLS
// origin to obtain the public-only ring and command. Never use a ticket URL.
final scope = CleanupScope(identityView.tenantId, identityView.deviceId!,
    identityView.registrationId!, proof.keyThumbprint);
final client = CleanupCommandClient(
    scope: scope, apiRoot: deploymentApiRoot,
    proofFactory: (action, operationId) =>
        identity.cleanupProof(action: action, operationId: operationId),
    nowMillis: hostTimeSource);
final command = await client.fetchAndVerify();
// This must be an atomic, durable, encrypted app-private record.
final journal = CleanupReceiptJournal(
    scope: scope, store: encryptedCleanupRecordStore,
    nowMillis: hostTimeSource);
await journal.load(command);
final receipt = await journal.prepare(CleanupReceiptStage.received);
final ack = await client.submitReceipt(receipt);
await journal.acknowledge(receipt, ack);
// A RECEIVED acknowledgement is not evidence of local deletion.
client.close();
```

`deploymentApiRoot` is a deployment-controlled HTTPS `/api/v1` URI, never a
value copied from a user, QR code or JWS header. The client obtains
the public ring and current command with separate fresh READ proofs, refuses
redirects and limits response time and size. The verifier accepts one
authenticated JWK set with at most 32 P-256 public
verification keys. It checks ES256, the cleanup-specific JOSE type, exact
registration and original-key thumbprint, command identity, fixed action list,
scope, schema and deadline. Unexpected fields or actions fail closed. The
verified result carries the command hash required for an eventual receipt.

The device identity SDK generates a new 60-second READ or RECEIPT proof from
the original registration key and computes its RFC 7638 public thumbprint.
Those proofs are bearer credentials until expiry and must not be logged or
persisted. A device API 401 alone never authorizes local deletion.

`submitReceipt` sends an explicit `CleanupReceipt` using a fresh RECEIPT proof
bound to the verified operation. `CleanupReceiptJournal` derives one stable
UUID v5 per signed command and stage, durably saves its exact body before the
first send, and returns that record after an unknown result. If the journal is
unexpectedly lost, a matching stage keeps the same ID; a changed failure
reason gets a server conflict instead of silently creating a second receipt.
A failed store write blocks progress until a fresh read; restoring a journal
requires the same newly verified command.
The returned operation is an accepted-receipt snapshot, not a live status
check. `AGENT_DATA_CLEARED` is permitted only after the host reports its own
idempotent data clear to the journal. No cleaner is included yet.

`CleanupCoordinator.runOnce()` now sequences command verification, replay of
any pending receipt, a received acknowledgement, the host's idempotent local
clear, the cleared acknowledgement, and final removal of the original key.
It requires an `AgentCleanupExecutor` supplied by the Android host; there is
no no-op implementation. A local clear error reports a fixed FAILED reason;
an unknown network response remains pending and blocks the next stage. The
final key-removal call occurs only after a `CLEANUP_REPORTED` acknowledgement
bound to the cleared receipt. The host must keep this app's cleanup journal
and original key until that point and must not clear third-party or system
data. This coordinator is not wired into the child runtime yet.

## Delivery state

Proof generation, command retrieval/verification, explicit receipt submission,
a reusable receipt journal and coordinator are present. The child runtime has
an encrypted journal store adapter, but has not wired the coordinator or
supplied a real cleanup executor. Local agent-data deletion, final key
removal, full reboot recovery and real Android/TV validation remain to be
built. This package itself has no path that directly deletes local data.
