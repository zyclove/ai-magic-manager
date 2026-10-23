# Usage report device picker — independent final static review

**Static no blocker for candidate SHA256 `10f70a11f6938d3c8545d8b10c8afedaff200adbaea211d86ae04c68e846b310`. UNFORMATTED / UNCOMPILED / UNRUN.** This supersedes the earlier draft assessment; it does not certify rendering or tests.

Before/Main SHA256 remains `c5a08c51ef3a4cd169ae237d9b7ac928426ee0664ad8d45f3cfbfe9e0c1bd3f7`. Only the Root-owned cache candidate was reviewed; this reviewer did not modify it or Main.

## Lifecycle and ownership

- Revocation35–59 is sticky and synchronous, clears selection, and cannot be revived by an observed false→true access change. During persistent frame callbacks it defers only setState, retaining the immediate invalidation. Build161–169/253 hides old private rows and actions behind the notice. An initial denial follows the same path.
- didUpdateWidget78–86 checks the former access closure, moves the listener and observes the new closure without resetting sticky state. Listener/controller/focus disposal95–99 is present. A getter observing revocation cannot restore old selection.
- editable62–67 requires current permission, an active/current route and Owned availability. A merely covering route does not itself invalidate the picker, but retained edit/confirm callbacks under the cover cannot act.
- finish102–119 separates null cancel from non-null confirm. Cancel needs the exact still-available Owned route, can finish it while covered, and never uses a global navigator pop. Its synchronous closing latch prevents another confirmation during reverse. Ordinary routes use only active/current public pop. No protected Route completion method was added.
- The caller UsageReportsView262–287 retains its original generation/route-identity/availability capture and current/generation check on return. Its independent loss/dispose closure remains intact. No scope or OwnedDialogRoute API was changed.

## Quantity/result gap closed

The first reviewed draft5b227cc5… had a P2: build-time enabling alone allowed retained bulk/row callbacks to exceed the current cap and a retained Confirm could return an oversized or empty set. This was an existing design weakness, not a demonstrated authorization vulnerability.

Current selectVisible137–143 recomputes visibleTargets from current search/selected-only state and current union, rejects overflow and never truncates. toggleDevice145–157 checks current allowed ID and capacity immediately before adding. Non-null finish105–110 repeats nonempty/limit/subset checks plus editable, so old callbacks cannot bypass them. Null cancellation is unaffected. The generic limit remains supplied by the caller; production's20/200 limits and other supplied limits use the same checks.

## Interaction/layout source assessment

The original two200-limit test names, button labels and data contracts remain compatible by inspection: more-than200 full selection stays disabled; filtered111 and exact200 remain explicit; Clear removes all selected entries. Search clear preserves selection, selected-only has an empty-state explanation, count is visible and shortId safely handles short IDs.

AlertDialog.scrollable plus mainAxisSize.min header and a separately sized lazy list removes the previous fixed-height Column/Expanded contention. Its inner list is bounded100–320 while the entire header/content can scroll; actions remain in the dialog action area. No claim is made that every short viewport, keyboard or text2x case has rendered successfully. The two original unit sources do not cover these new cases.

## Outstanding verification, all UNRUN

Add/run real owned-dialog sources for initial denial; false→true before pump; listener replacement; current/covered null close with a preserved independent cover; held Confirm before any reverse/dispose pump; stale row/bulk callbacks at the limit; stale Confirm after Clear; selected-only/filter/clear interactions; short IDs; and explicit reachable actions at narrow/short/text2x sizes. Keep the existing reports covered-owner-disposal case and the original200 cases. Do not replace no-pump assertions with checks only after disposal. No SDK/test/formatter/compiler/process API/network/Git action was performed by this review.
