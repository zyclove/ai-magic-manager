# Identity transport r2 — independent delta closeout

**IDENTITY-R1-01 is closed by static source review. No remaining blocker found in this delta. UNCOMPILED / UNRUN.** This does not prove real cancellation or passing tests.

Scope: only the r1-to-r2 test delta, its changed fixtures and exact preservation pins. The broader r1 review is not repeated or upgraded.

## Why the original gap is closed

In `ProviderHttpTransportTest.java:334–392`, A retains its original five-second budget. B starts around A's fourth second; the test waits for B's actual response headers and requires both calls still pending before A finishes (351–357). B's small, fixed-length body remains behind its own latch.

A must actually fail with `HttpTimeoutException` at 4.5–6 seconds while its body is still zero bytes. Only then is A's closure probe released; writer failure and handler end must precede fixture cleanup (359–369).

After that closure, the original B `sendAsync` Future, B's caller Future and B's body latch must still be pending, with no B body written (371–375). The test then releases the same B and requires status200, the complete JSON, successful server write/end, no fixture failure and exactly two submissions (376–384). Cancelling B during A's timeout can no longer pass merely because B completed earlier.

The observer returns the original real Future without wrapping or mapping it (518–529). The `/held` handler sends headers before awaiting its bounded latch (583–607). Finally paths release both latches and bound caller/server/executor shutdown (385–389,657–663). Production deadlines are unchanged; scheduling delays may make the test fail and do not create a green path.

## Exact static checks

- Manifest 28864B: `f5ae94c4b15a80870063bd954c48cd4b58864d404a8a4c14a7d2f89f9f3d8358`.
- Delivery17: `ae0f4af03c85dcbea6aefcce5685485c2af148dbace84d5493887300e6bce475`; all17 files match. Original r1's15 pinned files remain exact.
- Delta9841B: `9e6d354fdd17f5c0679cb3d85eb7b1d0f48b17e3570ef3ba2124be57e76f1575`; one test file only, fully read.
- Changed test31874B: `cb9b8131eedb97c0b76005ba4593c72b0c57344105e3698ca0b51a8090858164`. All22 test names/order unchanged. The other four overlay sources are byte exact to r1; saved r1 test bytes also match.

Only this new cache report was written. No candidate import, Java parser/compiler, SDK/test, process API, whole-cache scan, network, Main or Git mutation. Original r1 review and RED material remain unchanged. Projected98 remains a static count.
