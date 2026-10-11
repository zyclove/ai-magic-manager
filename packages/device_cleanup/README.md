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
bound to the verified operation. `CleanupReceiptJournal` durably saves the
exact receipt ID, stage and body before the first send, and returns that same
record after an unknown result. A failed store write blocks progress until a
fresh read; restoring a journal requires the same newly verified command.
The returned operation is an accepted-receipt snapshot, not a live status
check. `AGENT_DATA_CLEARED` is permitted only after the host reports its own
idempotent data clear to the journal. No cleaner is included yet.

## Delivery state

Proof generation, command retrieval/verification, explicit receipt submission
and a reusable receipt journal are present. The child runtime has not yet
wired this client or supplied a production encrypted store. Local agent-data
deletion, final key removal, full reboot recovery and real Android/TV
validation remain to be built. This package has no path that performs a local
destructive operation.
