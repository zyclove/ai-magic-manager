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
final verifier = CleanupCommandVerifier(
    scope: scope, trustedKeys: authenticatedPublicRing,
    nowMillis: hostTimeSource);
final command = await verifier.verify(response.compactJws,
    operationId: response.operationId,
    commandId: response.commandId,
    notAfter: response.notAfter);
// command is verified evidence, not a call to execute cleanup.
```

`authenticatedPublicRing` and `response` are placeholders for future
transport results, not values to copy from a user, QR code or the JWS header.
The verifier accepts one authenticated JWK set with at most 32 P-256 public
verification keys. It checks ES256, the cleanup-specific JOSE type, exact
registration and original-key thumbprint, command identity, fixed action list,
scope, schema and deadline. Unexpected fields or actions fail closed. The
verified result carries the command hash required for an eventual receipt.

The device identity SDK generates a new 60-second READ or RECEIPT proof from
the original registration key and computes its RFC 7638 public thumbprint.
Those proofs are bearer credentials until expiry and must not be logged or
persisted. A device API 401 alone never authorizes local deletion.

## Delivery state

Only proof generation and command verification are present. The cleanup HTTP
client, durable command/receipt journal, local agent-data deletion, final key
removal, reboot recovery and real Android/TV validation remain to be built.
This package has no path that performs a destructive operation.
