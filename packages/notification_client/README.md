# Notification client

Pure Dart extraction of the existing notification contract. Hosts inject their authenticated HTTP transport and a current-scope predicate. No browser APIs, storage, credentials, polling or Flutter dependency.

Validates bounded pages, ordering, identifiers, unread counts and exact selected read acknowledgements. Personal read operations are naturally idempotent; retries must retain the original selection. The backend remains authoritative for current tenant/member/subject access. Hosts must additionally invalidate asynchronous work on identity and foreground changes, and guard transport dispatch after token refresh.

`NotificationFailure` represents protocol/scope errors; host adapters translate it to their own user-facing error type. HTTP errors retain the host's correlation ID.
