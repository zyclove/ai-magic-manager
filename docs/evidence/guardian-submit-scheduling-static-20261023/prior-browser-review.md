# Browser80-r2 RED archive independent review

Static archive review: **no blocker**. This is not browser acceptance.

- Exact stage pin and explicit parent ab6d01becf72ce83a6159fcc59d08a42d963beb8 match. All 54 files / 448689 bytes match SHA256 and independently computed raw Git blob SHA1. All 50 raw copies are byte exact to their named originals; four generated files are the README, summary, inventory and attributes. The actual archive membership is exact. Inventory 53 rows plus its own stage row agree.
- Raw UTF-8 JSONL independently yields 135 events, 54 successful visible cases with exact expected selector/name membership, one pending test72, six observed suites, no error event and no terminal done. The 80/7 contract is preserved, with 26 expected cases unfinished including the pending case. Hidden loading successes do not count as visible cases.
- Receipt and result remain NOT_ACCEPTED: command210 deadline, native124/timeout, forced tree, sdkForced=null, auxCleanup=false, sdkRootNaturalZero=false and legacyStrictAccepted=false. Worker/outer natural1 and Jobs0 are consistent.
- Candidate pre-I/O245.5821743000015s is not used as actual outer exit. The separately archived prelaunch monotonic anchor and after-same-session terminal observation subtract to257.0758057999992s<300, with actual84534 /939a2c→c39c42 /natural1.
- Archived complete pre/post receipts and Root independent readback agree on381 descriptors(19+11+351), dual409 source,70 packages and3537 cache files/638537951B. This audit did not repeat large source/cache reads or process checks. Readback awaits fresh release; later formal gate at07:03:23.8068029Z records SDK0/unknown0/owned PIDs absent. Its release explicitly retains browser80Accepted=false and wholeProductAccepted=false. Root tool chunk21031e is external task context, not an embedded field that can be inferred from raw bytes.
- UNRUN preparation seals remain historical. The followup eight-site test-scheduling candidate remains UNRUN; no fixed test or successful rerun is inferred. No runtime/cache/tmp/source tree was copied into this archive.

Known original evidence limitation: Root captured readback contains 12 Chinese names with U+FFFD/encoding corruption (testIDs21-32). TestIDs/selectors/counts agree, and this archive preserves that original byte exact. Exact names must come only from raw UTF-8 JSONL plus expected80, which this audit independently matched; README already states that source boundary. No raw readback was repaired or replaced.

Only a new cache report was written. No candidate import, SDK, process API, network, Main or Git mutation.
