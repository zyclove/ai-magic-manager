# Picker input identity — independent delta review

**Static no blocker for final Main SHA256 `e980900a3d870c0293930801fb180cf25e566fe729d979f9aa29b6d11907ad4a`. UNFORMATTED / UNCOMPILED / UNRUN.** This review covers only the small input-identity increment after d01f720; it does not upgrade prior runtime evidence.

Baseline `before.dart` is byte pinned to `10f70a11f6938d3c8545d8b10c8afedaff200adbaea211d86ae04c68e846b310`. Interim20de67 is not the final reviewed version.

- initState88–93 explicitly assigns the original limit and an unmodifiable deviceId→(registrationId,subjectId,platform) value map before observing access. The identity strings are final fields on UsageReportTarget. The snapshot is independent of a caller's mutable List and contains no mutable per-target record values.
- Initial duplicate IDs94–95 are rejected. Every later observation61–67 checks the current limit, list length, unique-ID count and all tuple values. Removal[A,B]→[B], insertion, same-length ID replacement, registration/subject/platform replacement and adding duplicate rows cause sticky invalidation with an explicit changed-input message. A duplicate cannot be hidden by map deduplication.
- Names and list order do not participate, so a harmless rename/reorder preserves the one-time selection. The logic does not silently intersect/truncate an existing draft after its selectable identity changes.
- All edit/confirm paths still pass through current→observeAccess; invalidation clears selection and build renders the notice. The existing nonempty/cap/subset confirm check is retained. Null cancellation remains permission independent and finishes only the original available OwnedDialogRoute, including while covered; the synchronous closing latch is retained.
- No notification or polling was added to List. In-place changes are detected at the next build/access/action/listener observation. An unobserved A→B→A cannot be detected and is not claimed. Parent scope-generation checks remain necessary and unchanged.

Required future source cases, all UNRUN: same-State removal/in-place replacement and duplicates; independent registration/subject/platform and limit changes; sticky observed invalidation after restore; name-only/reorder continuation; held Confirm after input loss with no pump; current/covered null close. Retain both original200-cap tests and the earlier scope/callback scenarios. No SDK/parser/formatter/compiler/test/process API/network/Git/Main write was performed by this reviewer.
