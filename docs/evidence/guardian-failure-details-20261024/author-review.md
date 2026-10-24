# Failure details: static implementation

The existing FailureView now puts its natural-language notice and recovery actions first. A mature Material ExpansionTile reveals selectable error-code and correlation-ID rows only when requested. Missing/empty tracking IDs produce no empty row. No request body or raw unknown exception text is rendered.

Recovery callback rules are unchanged: retry appears only when provided; reauthentication appears only when provided for HTTP401 or unknown failures. When neither action is present there is no empty action Wrap. The technical disclosure has a48px minimum target, uses the existing muted typography, and keeps platform Material keyboard/semantics behavior.

The local PageStorage wrapper deliberately isolates ExpansionTile from an outer page storage bucket. Its value key is the(code, correlationId) pair. A changed failure therefore starts collapsed even under an outer PageStorageKey; the same failure keeps its live expansion state when callbacks change. No custom StatefulWidget/controller/lifecycle or new dependency was introduced. The extra wrapper is justified by the installed SDK ExpansionTile.initState/readState and onExpansionChanged/writeState behavior, rather than assuming ValueKey alone overrides storage restoration.

Nine new widget-test source cases use a normal PageStorageKey on the host scroll view. They cover collapsed/toggle/selectable diagnostics, direct recovery actions and busy callback removal,401/non401/unknown reauth rules, code or tracking identity changes, private exception hiding, empty tracking IDs, UsageReportFailure mapping and320px/text1.8 operation. These are explicit declarations, not actual test results.

The changed production span is only FailureView; all source bytes outside the class match the saved Ace559e base. Original181 regression roots are retained, and the dedicated failure_view_test.dart adds one VM root, making182 current roots. The previous frozen21-case source cannot validate this newer component.

All new tests remain UNRUN. No Dart/Flutter SDK, AST/parser/compiler/formatter, browser, network, installer, external provider or Git mutation was invoked. The installed ExpansionTile source was read only to check its API and storage behavior. No rendering, compile compatibility or keyboard behavior is claimed as verified.
