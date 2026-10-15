@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';
import 'managed_enrollment_page_test.dart' as fixture;
import 'managed_agent_binding_fixtures.dart';

void main() {
  testWidgets('verified enrollment exposes the child binding workflow',
      (tester) async {
    final session = fixture.EnrollmentSession(bound: true)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    expect(find.text('关联儿童端'), findsOneWidget);
  });
  testWidgets(
      'real page opens scoped selection and closes it on workspace invalidation',
      (tester) async {
    final binding = AgentBindingFixture();
    final session = fixture.EnrollmentSession(
        bound: true,
        extra: (r) async =>
            r.url.path.contains('/agent-bindings') ? binding.handle(r) : null)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    await tester.ensureVisible(find.text('关联儿童端'));
    await tester.tap(find.text('关联儿童端'));
    await fixture.settle(tester);
    expect(find.text('学习平板'), findsOneWidget);
    session.invalidate();
    await fixture.settle(tester);
    expect(find.byType(ManagedAgentBindingDialog), findsNothing);
    expect(binding.createCount, 0);
  });
  testWidgets('auditor can inspect current association but cannot mutate',
      (tester) async {
    final binding = AgentBindingFixture()
      ..binding = AgentBindingFixture().record(state: 'VERIFIED', version: 2);
    final session = fixture.EnrollmentSession(
        bound: true,
        actorRole: 'AUDITOR',
        extra: (r) async =>
            r.url.path.contains('/agent-bindings') ? binding.handle(r) : null)
      ..rows = [fixture.row(state: 'VERIFIED', version: 2)];
    await fixture.mount(tester, session);
    await tester.ensureVisible(find.text('查看儿童端关联'));
    await tester.tap(find.text('查看儿童端关联'));
    await fixture.settle(tester);
    expect(find.text('儿童端身份已核验'), findsOneWidget);
    expect(find.text('撤销此关联'), findsNothing);
    expect(find.text('开始关联'), findsNothing);
  });
}
