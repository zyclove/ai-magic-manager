# Provider HTTP total deadline — static implementation

Three production files share a JDK17 request transport. It keeps the original
sendAsync Future, uses one five-second monotonic budget, reads at most65536 actual
body bytes, and cancels the current exchange on timeout or interruption.
The factory client is borrowed; no executor, timer, dependency or application
retry was added. Both adapters retain their request construction. JSON response
decoding is explicitly UTF-8, including the WeChat adapter.

Two test files contain the async mock adaptation and22 new test declarations.
The projected complete module has98 declarations; none has been compiled or run
for this implementation. Two independent reviews found no remaining confirmed
static blocker. The r1 concurrent-request coverage gap is closed in r2 source:
B remains in flight until after A times out and its network close is observed.
That sequence and actual cancellation still require runtime verification.

The original77/79 RED evidence and historical test-first18 checkpoint remain
unchanged. A later64KiB limit rejection must not be reported as passing the old
4MiB deadline fixture. New bounded-body deadlines and oversize cases are separate.
JDK cancellation is best effort; HTTP/2 and physical cleanup remain unverified.
An arbitrarily blocking custom Supplier/sendAsync cannot be preempted by these
post-return deadline checks. See the retained reviews and design for boundaries.

Candidate manifests and reviews are exact pre-application checkpoints. No POM,
factory, deployment or current service was changed. Whole-product acceptance is
incomplete. Compile and run the complete offline module in a new qualified window
before deploying this source.
