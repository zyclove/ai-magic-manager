# Independent Help pagination candidate review r1

Status: **STATIC_NO_BLOCKER** for after SHA256 `c299fd7a069501d45462f8cac89327d4bc811426ca37c465145f8bc9ff368eb3`. The complete before/after, patch, delivery inventory and author review were read. This review did not author or modify the candidate, Main, Git or previous seals. No code parser, candidate import/execution, SDK, test, formatter, build, network, native/process API or rendered UI was used. All scenarios remain **UNRUN**.

## Requested recovery paths

- `pageError` is independent of the existing initial-read/acknowledgement `error` (25). Append start clears only pageError (65-67). Append catch writes only pageError, retaining rows, ordinary cursor and unknown acknowledgement state (89-100). Append success no longer clears `uncertain`; that clear is restricted to the original fresh-success path (84-86). Thus a successful or failed page retry does not erase an acknowledgement error or unlock an uncertain acknowledgement without rereading the original records.
- `retryMore` rechecks current, both busy states, a non-null current cursor and a still-present pageError before entering `load(more:true)` (112-117). The loader synchronously clears pageError/sets loadingMore; a second held retry or a held retry after success cannot start another request. Ordinary append failure retries its retained cursor and does not clear accumulated rows.
- Append INVALID_CURSOR clears cursor while retaining rows/pageError (94-96). Its UI gives one recovery notice and an explicit fresh refresh (220-229); ordinary load-more is hidden. A previously held retryMore/load-more callback cannot reuse the rejected cursor. The dedicated refresh rechecks current, both busy states and a currently invalid pageError (119-122), so its old callback cannot clear a successful new page.
- Fresh loading remains available when the initial loading flag is true because the new busy/cursor condition is specific to `more` (59-60). Fresh starts synchronously clear loadingMore and advance generation, preserving explicit refresh/filter/acknowledgement-success supersession of a previous append. The original generation checks reject that old append's success, catch and finally; no global busy guard was added to discard a necessary fresh reload.

## Reauthentication and acknowledgement contract

The append FailureView at 231-237 **does retain reauth**: it checks current before calling `sessionOwner.login(stepUp:true)`. Existing FailureView shows its supplied reauth action for status 401 (design.dart:196-200), so separating append errors did not remove the previous 401 recovery action. The original global error/warning/retry/reauth block at 193-203 is unchanged.

The acknowledgement method is byte-identical: same confirmation text, scope-bound POST, item.version, response identity/state check, sending/uncertain logic and existing fresh reload. Row rendering and its uncertain/sending disable logic are also byte-identical. Scope/current/init/dispose and existing global recovery UI are verified by direct text comparison, not parser or runtime execution. This review does not claim to solve pre-existing fresh-read/acknowledgement races, multiple confirmation dialogs or acknowledgement semantics beyond the requested pagination delta.

## Integrity and remaining validation

`review-pins.json` records the actual five delivery descriptors, candidate pins/dependency descriptors, exact patch reconstruction, original Main/before identity and reviewed helper inputs. The top-level candidate membership remains the original five files plus the self-excluded delivery inventory. No candidate originals were changed.

Required later checks remain UNRUN: ordinary append error and same-cursor retry; concurrent acknowledgement uncertainty surviving failed/successful append; 401 append reauthentication; invalid cursor refresh; held retry/refresh after success; duplicate activation and loading guards; filter/fresh supersession with late responses; scope loss and actual rendering. Static review is not compilation, test success, execution authorization or deployment acceptance.
