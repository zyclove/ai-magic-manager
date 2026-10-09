# Device policy reception

Reusable Dart/Flutter configuration reception, using `jose` for ES256 and
Sembast for transactions. This package does not grant DPC privileges or perform
native application enforcement. Only the current `CONFIGURE_ONLY` protocol is
accepted. Full integration requirements and evidence are in
[the device reception contract](../../docs/device-configuration-client-contract.md).

## Host integration

```dart
final verifier = ConfigurationVerifier(
  scope: provisionedScope,       // trusted enrollment facts, not message fields
  trustedKeys: authenticatedRing,
  nowMillis: trustedTimeSource,
);
final journal = ConfigurationJournal(database: applicationPrivateDatabase,
  verifier: verifier);
final recoveredConfigurations = await journal.restore();
final transport = DeviceConfigurationTransport(
  apiRoot: Uri.parse(configuredHttpsApiRoot), // ends in /api/v1
  credential: readCurrentDeviceCredential,  // async secure-storage callback
);
final synchronizer = DeviceConfigurationSynchronizer(
  journal: journal, transport: transport, pageSize: 10, maxPages: 5,
);
try {
  final result = await synchronizer.synchronize();
  // result.hasMore: schedule a subsequent bounded job, never skip pages.
  // result.systemEnforced is always false; native execution is separate.
} on DeviceTransportFailure catch (failure) {
  final delay = synchronizer.retryDelay(failure, consecutiveAttempt);
  // Host schedules retry only if delay != null; authentication needs recovery.
} finally {
  synchronizer.close(); // create a new coordinator for the next host lifetime
}
```

The host supplies the private database, trusted scope/ring/time, credential
storage, OS scheduling and native adapters. The snippet names the provisioned
scope, private database, trusted time and secure-storage callback; those remain
host services. The transport uses the mature `http` SDK with bounded abortable
requests, HTTPS and redirect refusal. Each request reads a fresh opaque device
credential; user JWTs are rejected. The coordinator verifies and commits the
whole page plus `nextAfter` atomically, and deletes receipts only after validating
an authenticated acknowledgement. An unknown POST outcome retains the original
receipt ID/body for replay. Current receipt stage is `STORED`, never `APPLIED`.
Delivery expiry applies to a new first reception, not restoration. Signing-key
retrieval does not automatically install or replace the pinned trust ring.

Use one Sembast database owner per process. Its file database loads documents
into memory; configure supported policy/receipt capacity and storage budgets.
Restrict the database directory to the application and exclude it from logs or
shared backups. This package does not encrypt the file or provide hardware
rollback protection. Credentials and private signing keys do not belong here.

## Verification

```powershell
dart pub get
dart analyze
dart test
dart test test/verifier_test.dart --platform chrome
# Given a verified Spring Boot executable JAR:
./tool/verify-nimbus.ps1 -BackendJar /path/to/manager-backend.jar
# Real Spring HTTP / Dart interoperability (from the repository root):
mvn -f backend/pom.xml test '-Dtest=DeviceConfigurationHttpInteropTest' `
  '-Ddevice.dart.command=/absolute/path/to/dart-executable' `
  '-Ddevice.policy.package=/absolute/path/to/packages/device_policy'
```

`verify-nimbus.ps1` uses the real backend signer/record classes and Nimbus jars
from the supplied artifact. It creates a restricted ignored workspace with a
temporary test key, deletes the private key on exit, and retains public evidence.
VM file recovery tests are not Android reboot, browser storage or native system
enforcement evidence.

The HTTP test is opt-in for a backend-only Maven run: without
`device.dart.command`, JUnit explicitly skips it. `scripts/build-deployment.ps1`
opts in automatically when this package and the test exist, resolving Dart
dependencies before Maven. The real HTTP test uses isolated H2, explicit adult
and registration bootstrap fixtures, real opaque authentication, Nimbus, JOSE
and Sembast; it is not enrollment, real parent MFA or Android execution evidence.
Loopback HTTP is allowed only by an explicit test configuration. See the contract
for the retry, offline, browser and native integration boundaries.
