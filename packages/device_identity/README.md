# Device identity lifecycle

Pure Dart enrollment, original-key recovery, replayable heartbeats and two-phase
opaque credential rotation. It uses `jose` for cryptography and `http` for
abortable network requests. It grants no administrator role, DPC privileges or
native application enforcement.

```dart
final api = DeviceIdentityApi(apiRoot: confirmedHttpsApiRoot);
final identity = DeviceIdentityManager(
  api: api,
  secrets: encryptedApplicationPrivateStore,
  nowMillis: hostTimeSource,
);
await identity.begin(parentIssuedTicket,
  displayName: reportedDeviceName, osVersion: reportedOsVersion);
final physicalPairingCode = await identity.pairingCode();
// A guardian confirms that code through the adult API, with recent MFA.
await identity.heartbeat(agentVersion: agentVersion, capabilities: grantedFacts);
final safeUiFacts = await identity.view();
// Pass identity.activeCredential as the callback to DeviceConfigurationTransport.
// Its verifier scope/ring/time and native execution remain separate host inputs.
```

The example's storage, trusted service selection, parent-issued ticket, time,
granted capability observations and native host are integration inputs. There is
no plaintext production secret adapter. Implement `DeviceSecretStore` with one
atomic durable encrypted application-private record, one owner, no shared backup
or credential logging. A software JWK handle must stay inside that encrypted
record; `DeviceEnrollmentKeys` supports a future native non-exportable alias
adapter. The default JOSE provider does not prove hardware identity.

## Recovery rules

| Persisted phase | Explicit next action |
|---|---|
| `claimUncertain` | Original-key `recoverClaim`; if the original claim never reached the server, explicit `retryClaim`. No new key, automatic registration or reset. |
| `awaitingConfirmation` | Display physical pairing code and bounded heartbeat checks. A 401 does not prove revocation or authorize local confirmation. |
| `active` | Observe capabilities, send persisted heartbeats, receive configurations; local phase does not prove system enforcement. |
| `rotationRequested` | If the staging response was lost, cancel using the durable old credential before starting another rotation. |
| `rotationPending` | Old credential stays active; activate with the saved new credential. Expired unsent activation needs explicit cancellation. |
| `activationUncertain` | Retry activation with the new credential, even after its activation deadline, until its credential expires. Never fall back to the old credential. |

A pending heartbeat replays the same sequence/body. `replayed=true` tells the
host to schedule a newer snapshot separately. ACK requires exact registration,
safe integer sequence and receipt time. Active 401/403 persists an authentication
block: the configuration callback returns null, while identity/keys/pending work
remain. An explicit successful authenticated operation clears it. No automatic
retry or erase occurs. Admin confirmation must be demonstrated by an actual
successful authenticated heartbeat, never by tapping a local button.

All API roots are confirmed HTTPS addresses ending in `/api/v1`; redirects are
refused. Loopback HTTP is explicitly test-only. Requests cover headers/body with
a default 20-second deadline and default 64 KiB response bound. Errors omit
server copy, credentials, pairing codes, private material and SDK causes.

## Verification

```powershell
dart pub get
dart analyze
dart test
dart test test/keys_test.dart --platform chrome
# Repository root; quote Maven properties in PowerShell:
mvn -f backend/pom.xml test '-Dtest=DeviceIdentityHttpInteropTest' `
  '-Ddevice.dart.command=/absolute/path/to/dart-executable' `
  '-Ddevice.identity.package=/absolute/path/to/packages/device_identity'
```

Backend-only Maven skips the cross-SDK test unless `device.identity.package` is
set. `scripts/build-deployment.ps1` resolves the package, opts in and runs the
complete package gates. The Java test bootstraps only adult JWT/MFA fixtures;
device registration/proof/credentials use real Spring HTTP/Nimbus controllers.
Its isolated file store is deliberately an unencrypted test substitute, deleted
with its ticket and private key on exit; it is not shipped as a production store.

[Contract and evidence](../../docs/device-identity-client-contract.md) distinguish
actual protocol results from native encryption, hardware, reboot, TV, real MFA
and system enforcement gates.
