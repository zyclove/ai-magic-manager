import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';

import 'managed_execution_fixtures.dart';

Matcher invalidExecution() => isA<ApiFailure>().having(
    (failure) => failure.code,
    'code',
    'INVALID_MANAGED_EXECUTION_RESPONSE');

void main() {
  test('new recheck task reason is readable and remains waiting', () {
    final fixture = ExecutionFixture();
    ManagedExecution? task;
    expect(
        () => task = ManagedExecution.parse(
            fixture.record(
                state: 'WAITING_DEVICE',
                reason: 'MANUAL_DEVICE_RECHECK_REQUESTED',
                revision: 2,
                updatedAt: 101),
            deviceId: executionDevice),
        returnsNormally,
        reason: 'The existing strict task parser must support the new reason.');
    expect(task!.state, 'WAITING_DEVICE');
    expect(task!.reasonLabel, '已申请重新核实设备状态');
    expect(task!.cancellationRequested, isFalse);
  });

  test('new recheck event reason is readable without claiming applied', () {
    final fixture = ExecutionFixture();
    ManagedExecutionEvent? event;
    expect(
        () => event = ManagedExecutionEvent.parse(fixture.event(
            state: 'WAITING_DEVICE',
            reason: 'MANUAL_DEVICE_RECHECK_REQUESTED',
            revision: 2)),
        returnsNormally,
        reason: 'The existing strict event parser must support the new reason.');
    expect(event!.state, 'WAITING_DEVICE');
    expect(event!.reasonLabel, '已申请重新核实设备状态');
  });

  test('unknown task reason still fails closed', () {
    final fixture = ExecutionFixture();
    expect(
        () => ManagedExecution.parse(
            fixture.record(reason: 'RAW_PROVIDER_REASON'),
            deviceId: executionDevice),
        throwsA(invalidExecution()));
  });

  test('unknown event reason still fails closed', () {
    final fixture = ExecutionFixture();
    expect(
        () => ManagedExecutionEvent.parse(
            fixture.event(reason: 'RAW_PROVIDER_REASON')),
        throwsA(invalidExecution()));
  });

  test('task projection still rejects extra internal fields', () {
    final fixture = ExecutionFixture();
    final raw = fixture.record()..['providerVersion'] = 7;
    expect(
        () => ManagedExecution.parse(raw, deviceId: executionDevice),
        throwsA(invalidExecution()));
  });

  test('event projection still rejects extra internal fields', () {
    final fixture = ExecutionFixture();
    final raw = fixture.event()..['leaseToken'] = 'fixture-internal';
    expect(() => ManagedExecutionEvent.parse(raw),
        throwsA(invalidExecution()));
  });
}
