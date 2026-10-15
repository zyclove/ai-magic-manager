import 'package:flutter/material.dart';
import '../core/managed_android.dart';
import 'design.dart';

/// Presentation only: never grants enrollment permission or device capability.
class ManagedEnrollmentGuide extends StatelessWidget {
  final ManagedEnterpriseBinding? binding;
  final ManagedProvisioningReadiness readiness;
  final ManagedCapacitySnapshot capacity;
  final bool writable, enabled;
  final VoidCallback onPropose, onIssue;

  const ManagedEnrollmentGuide(
      {super.key,
      required this.binding,
      required this.readiness,
      required this.capacity,
      required this.writable,
      required this.enabled,
      required this.onPropose,
      required this.onIssue});

  @override
  Widget build(BuildContext context) {
    final canIssue = binding?.state == 'ACTIVE' &&
        readiness.canIssueEnrollment &&
        capacity.availableForNew > 0;
    final String title;
    final String detail;
    if (binding == null) {
      title = '先申请机构资格审核';
      detail = '准备企业资源 ID 和已生效合同编号。提交一次，由平台独立审核。';
    } else if (binding!.state == 'PENDING') {
      title = '等待平台审核';
      detail = '申请已提交，无需重复申请。审核完成后刷新此页，继续接入设备。';
    } else if (binding!.state == 'REVOKED') {
      title = '请联系平台复核机构资格';
      detail = '绑定已撤销，暂不能新增注册。已注册设备仍需单独核对管理状态。';
    } else if (!readiness.canIssueEnrollment) {
      title = '机构已审核，接入条件待补齐';
      detail = readinessExplanation(readiness.reasonCode);
    } else if (!canIssue) {
      title = '先处理设备名额';
      detail = '当前可新增 0 台。请核对合同或处理下方待核对、待清理记录；取消令牌不会立即释放名额。';
    } else {
      title = '可以开始接入设备';
      detail = '选择学生档案，生成一次性二维码。待注册设备完成注册后，再核对设备身份。';
    }
    return SizedBox(
        width: double.infinity,
        child: Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('下一步', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(detail),
          if (binding == null &&
              readiness.reasonCode != 'BINDING_REQUIRED') ...[
            const SizedBox(height: 8),
            Text(readinessExplanation(readiness.reasonCode),
                style: const TextStyle(color: muted)),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            _step(
                context, 1, '机构资格', binding?.state == 'ACTIVE' ? '已审核' : '待完成'),
            _step(context, 2, '注册资料', canIssue ? '可创建' : '待条件就绪'),
            _step(context, 3, '设备身份', '逐台核对'),
          ]),
          const SizedBox(height: 16),
          if (!writable)
            const Text('当前为只读查看，请由机构管理员完成操作。', style: TextStyle(color: muted))
          else if (binding == null)
            FilledButton.icon(
                onPressed: enabled ? onPropose : null,
                icon: const Icon(Icons.domain_add_outlined),
                label: const Text('申请机构审核'))
          else if (canIssue && binding!.state == 'ACTIVE')
            FilledButton.icon(
                onPressed: enabled ? onIssue : null,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('接入一台设备')),
          const SizedBox(height: 12),
          const Text('注册核验不代表应用限制已生效。管控效果需单独查看真实设备绑定和执行回执。',
              style: TextStyle(color: muted)),
        ])));
  }

  Widget _step(BuildContext context, int number, String title, String state) =>
      Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: canvas, borderRadius: BorderRadius.circular(8)),
          child: Text('$number  $title · $state'));
}

String readinessExplanation(String reason) => switch (reason) {
      'REGION_PROVIDER_UNAVAILABLE' => '中国大陆当前未开通此提供方。请联系平台接入已审核的本地合作提供方。',
      'PROVIDER_NOT_CONFIGURED' => '提供方尚未开通，可以先申请机构审核；开通前不能生成注册资料。',
      'BINDING_REQUIRED' => '请先申请机构审核。',
      'BINDING_REVIEW_PENDING' => '机构申请正在等待平台独立审核。',
      'BINDING_REVOKED' => '机构绑定已撤销，请联系平台复核。',
      'PROVIDER_CHANGED' => '提供方已变更，请联系平台完成企业资源迁移。',
      'CONTRACT_REQUIRED' => '请联系机构合同负责人补齐有效的受管 Android 权益。',
      'BOOTSTRAP_POLICY_REQUIRED' => '请联系平台管理员完成初始安全策略配置。',
      'PROVISIONING_CONFIGURED' => '接入条件已配置，创建时仍会实时核对提供方和初始安全策略。',
      _ => '暂时无法确认接入条件，请刷新重试。',
    };

/// Expiry changes the instruction, not the server state or release of a seat.
({String title, String detail}) enrollmentInstruction(
        ManagedEnrollmentIntent intent, DateTime now) =>
    switch (intent.state) {
      'PREPARING' => (title: '正在准备', detail: '请刷新查看结果，暂勿为同一档案重复创建。'),
      'ISSUED' when now.millisecondsSinceEpoch >= intent.expiresAt => (
          title: '资料已到期，待核对',
          detail: '若设备已完成注册，请补做身份核对；否则取消令牌并核对清理结果。到期不会自动释放名额。'
        ),
      'ISSUED' => (
          title: '等待设备注册',
          detail: '请用待注册设备扫描一次性二维码。注册完成后，填写提供方设备 ID 核对身份。'
        ),
      'VERIFIED' => (
          title: '身份已核对',
          detail: '可实时复核提供方的初始策略状态；本地儿童 App 尚未建立受管身份绑定。'
        ),
      'CANCEL_PENDING' => (
          title: '取消处理中',
          detail: '提供方清理尚未完成，请稍后刷新。设备若已注册，仍可补做身份核对。'
        ),
      'CANCELLED' => (
          title: '令牌已取消',
          detail: '不能据此认定设备未注册或已退管。若此前已注册，请补做身份核对。'
        ),
      'FAILED' => (title: '创建未完成', detail: '请先刷新核对记录及可用名额，再决定是否重新创建。'),
      _ => (title: '状态待确认', detail: '请刷新后查看最新结果。'),
    };
