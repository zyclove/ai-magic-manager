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
final after = await journal.cursor();
// Pull from the authenticated device endpoint, in ascending cursor order.
for (final item in verifiedTransportPage) {
  await journal.accept(item.compactJws);
}
for (final receipt in await journal.pendingReceipts()) {
  await deviceApi.sendReceipt(receipt.toJson());
  await journal.acknowledge(receipt.receiptId);
}
```

The host supplies the private database, trusted scope/ring/time, credential
storage, authenticated transport and native adapters. The snippet names those
host services; they are not implemented by this package. Do not persist a page's
`nextAfter` ahead of the accepted items. Current receipt stage is `STORED`, never
`APPLIED`. Delivery expiry applies to a new first reception, not restoration.

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
```

`verify-nimbus.ps1` uses the real backend signer/record classes and Nimbus jars
from the supplied artifact. It creates a restricted ignored workspace with a
temporary test key, deletes the private key on exit, and retains public evidence.
VM file recovery tests are not Android reboot, browser storage or native system
enforcement evidence.
