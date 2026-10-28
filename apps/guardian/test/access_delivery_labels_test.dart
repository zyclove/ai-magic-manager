import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/labels.dart';

void main() {
  test('approval delivery labels keep transport separate from execution', () {
    expect(label('NOT_FETCHED'), '等待设备获取当前文档');
    expect(label('SIGNED'), '文档已签名 · 尚无回执');
    expect(label('REMOVE_ACCESS_WINDOW'), '撤回访问窗口');
    expect(label('DEVICE_REPORT_UNVERIFIED'), '设备报告 · 未验证执行');
    expect(label('NOT_ENFORCED'), '尚未执行');
    expect(label('APPROVED_PENDING_DELIVERY'), '已批准 · 尚未执行');
  });
  test('device rejection reasons describe the cause without exposing codes',
      () {
    expect(accessRejectionLabel(null), '—');
    expect(accessRejectionLabel('STORAGE_FAILED'), '设备暂时无法保存文档');
    expect(accessRejectionLabel('BASELINE_MISSING'), '缺少对应的基础配置');
    expect(accessRejectionLabel('SIGNATURE_INVALID'), '签名校验未通过');
  });
  test('retry diagnostics distinguish waiting, availability and exhaustion',
      () {
    expect(accessRetryLabel('WAITING'), '等待重试间隔');
    expect(accessRetryLabel('AVAILABLE'), '设备可再次尝试');
    expect(accessRetryLabel('EXHAUSTED'), '已达 10 次上限，需要排查');
    expect(accessRetryLabel('WINDOW_ENDING'), '剩余批准时间不足以重试');
    expect(label('ACCESS_DOCUMENT_RETRIED'), '重新尝试审批文档交付');
  });
  test('date labels reject malformed numeric epochs without changing valid text',
      () {
    final local = DateTime(2024, 1, 2, 3, 4);
    final milliseconds = local.millisecondsSinceEpoch;
    expect(dateLabel(null), '—');
    for (final value in <Object>[
      milliseconds,
      milliseconds.toDouble(),
      local.toUtc().toIso8601String(),
    ]) {
      expect(dateLabel(value), '2024-01-02 03:04');
    }
    for (final value in <num>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
      1730000000000.5,
      -0.5,
      8640000000000001,
      -8640000000000001,
      1e300,
    ]) {
      expect(dateLabel(value), '时间无效');
    }
    expect(dateLabel('unknown-time'), 'unknown-time');
  });
}
