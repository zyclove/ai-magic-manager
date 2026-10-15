# Audit client contracts

Pure Dart, read-only models shared by the parent app and management console.
The package owns the half-open query range, exact event projection, page size,
descending time/ID ordering and filter matching checks. It has no HTTP, storage,
authentication or Flutter dependency. Both repositories adapt protocol failures
to their own application error types; server authorization remains authoritative.

Queries are at most 366 elapsed days; event timestamps must fit years 1970–9999.
The query end is exclusive. UI calendar ranges must use local next-day midnight,
not a fixed 24-hour addition across daylight-saving transitions. Results are
live reads rather than transaction snapshots. An audit action records a server
operation and does not certify successful device enforcement.

`exports.dart` also owns export job/page projections and artifact validation:
creator-bound metadata, exact selection and job/tenant identity, a maximum of
10,000 events and 8 MiB, event ordering and no extra event fields. Transport,
recent authentication, bounded byte streams, recovery and destination selection
remain responsibilities of the consuming applications. Payload checks do not
replace server authorization or certify device enforcement.
