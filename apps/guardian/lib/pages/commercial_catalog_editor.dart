import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/commercial_catalog.dart';
import '../core/commercial_catalog_repository.dart';
import '../ui/design.dart';

/// Complete draft editor. An uncertain create keeps its UUID and payload for exact replay.
class CommercialCatalogEditor extends StatefulWidget {
  final CommercialCatalogRepository repository;
  final CatalogOffer? existing;
  const CommercialCatalogEditor(
      {super.key, required this.repository, this.existing});

  @override
  State<CommercialCatalogEditor> createState() =>
      _CommercialCatalogEditorState();
}

class _CommercialCatalogEditorState extends State<CommercialCatalogEditor> {
  final form = GlobalKey<FormState>();
  late final String id;
  late final TextEditingController sku,
      version,
      region,
      currency,
      amount,
      capacity;
  late String channel,
      buyerKind,
      platform,
      deviceMode,
      period,
      priceType,
      tax,
      capacityKind;
  late Set<String> features;
  late DateTime starts, ends;
  CatalogDraft? retryDraft;
  Object? error;
  bool saving = false;

  Map<String, dynamic> get initial => widget.existing?.offer ?? const {};

  @override
  void initState() {
    super.initState();
    id = widget.existing?.id ?? widget.repository.newId();
    sku = TextEditingController(text: initial['sku'] as String? ?? '');
    version = TextEditingController(text: '${initial['skuVersion'] ?? 1}');
    region = TextEditingController(text: initial['region'] as String? ?? 'CN');
    currency =
        TextEditingController(text: initial['currency'] as String? ?? 'CNY');
    amount = TextEditingController(text: '${initial['priceMinor'] ?? ''}');
    capacity = TextEditingController(text: '${initial['deviceCapacity'] ?? 1}');
    channel = initial['channel'] as String? ?? 'CONTRACT';
    buyerKind = initial['buyerKind'] as String? ?? 'ORGANIZATION';
    platform = initial['platform'] as String? ?? 'ANDROID';
    deviceMode = initial['deviceMode'] as String? ?? 'BYOD';
    period = initial['billingPeriod'] as String? ?? 'YEAR';
    priceType = initial['priceType'] as String? ?? 'QUOTE';
    tax = initial['taxBasis'] as String? ?? 'QUOTE_REQUIRED';
    capacityKind = initial['capacityKind'] as String? ?? 'BASE';
    features = Set<String>.from(initial['features'] as List? ?? const []);
    starts = DateTime.fromMillisecondsSinceEpoch(initial['availableFrom']
            as int? ??
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
    ends = DateTime.fromMillisecondsSinceEpoch(initial['availableUntil']
            as int? ??
        DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch);
  }

  @override
  void dispose() {
    for (final controller in [
      sku,
      version,
      region,
      currency,
      amount,
      capacity
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? requiredText(String? value) =>
      value == null || value.trim().isEmpty ? '此项为必填项' : null;

  String? positiveInteger(String? value, {bool allowZero = false}) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed == null || parsed < (allowZero ? 0 : 1)
        ? '请输入${allowZero ? '非负' : '正'}整数'
        : null;
  }

  CatalogDraft? draft() {
    if (!(form.currentState?.validate() ?? false)) return null;
    if (!ends.isAfter(starts)) {
      setState(() => error = const ApiFailure(400, 'INVALID_COMMERCIAL_OFFER'));
      return null;
    }
    if ((channel == 'GOOGLE_PLAY' &&
            !['ANDROID', 'ANDROID_TV'].contains(platform)) ||
        (channel == 'APP_STORE' && platform != 'IOS') ||
        (deviceMode == 'WORK_PROFILE' && platform != 'ANDROID') ||
        (features.contains('MANAGED_ANDROID') &&
            (deviceMode == 'BYOD' ||
                !['ANDROID', 'ANDROID_TV'].contains(platform))) ||
        (features.contains('ORG_BULK') && buyerKind != 'ORGANIZATION')) {
      setState(() =>
          error = const ApiFailure(400, 'INVALID_COMMERCIAL_APPLICABILITY'));
      return null;
    }
    return CatalogDraft({
      'sku': sku.text.trim().toUpperCase(),
      'skuVersion': int.parse(version.text.trim()),
      'region': region.text.trim().toUpperCase(),
      'channel': channel,
      'buyerKind': buyerKind,
      'platform': platform,
      'deviceMode': deviceMode,
      'billingPeriod': period,
      'priceType': priceType,
      'currency': currency.text.trim().toUpperCase(),
      'priceMinor': priceType == 'QUOTE' ? null : int.parse(amount.text.trim()),
      'taxBasis': priceType == 'QUOTE' ? 'QUOTE_REQUIRED' : tax,
      'capacityKind': capacityKind,
      'deviceCapacity': int.parse(capacity.text.trim()),
      'features': features.toList()..sort(),
      'availableFrom': starts.millisecondsSinceEpoch,
      'availableUntil': ends.millisecondsSinceEpoch
    });
  }

  Future<void> save() async {
    if (saving) return;
    final payload = retryDraft ?? draft();
    if (payload == null) return;
    if (retryDraft == null && !await review(payload)) return;
    if (!mounted) return;
    setState(() {
      saving = true;
      error = null;
      retryDraft = payload;
    });
    try {
      final result = widget.existing == null
          ? await widget.repository.create(id, payload)
          : await widget.repository.revise(widget.existing!, payload);
      if (mounted) Navigator.of(context).pop(result);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = failure;
        saving = false;
        // Keep exact payload only when the request could have reached the server.
        if (failure is ApiFailure &&
            failure.status >= 400 &&
            failure.status < 500) {
          retryDraft = null;
        }
      });
    }
  }

  Future<bool> review(CatalogDraft payload) async {
    final before = initial;
    final after = payload.toJson();
    final changed = after.keys
        .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
        .toList();
    if (changed.isEmpty) {
      setState(() => error = const ApiFailure(400, 'NO_CHANGES'));
      return false;
    }
    String value(String key, Object? raw) {
      if (raw == null) return '未设置';
      if (key == 'availableFrom' || key == 'availableUntil') {
        return DateFormat('yyyy-MM-dd HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(raw as int));
      }
      if (raw is List) {
        return raw.isEmpty
            ? '未配置'
            : raw.map((item) => catalogLabel(item.toString())).join('、');
      }
      return catalogLabel(raw.toString());
    }

    final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(widget.existing == null ? '核对新草稿' : '核对修订内容'),
                content: SizedBox(
                    width: 560,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Notice('内部草稿不会对客户售卖，也不会产生权益。请核对以下字段。'),
                          const SizedBox(height: 14),
                          for (final key in changed)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_previewLabels[key] ?? key,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600)),
                                      if (widget.existing != null)
                                        Text('原值：${value(key, before[key])}',
                                            style:
                                                const TextStyle(color: muted)),
                                      Text('新值：${value(key, after[key])}')
                                    ]))
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('返回修改')),
                  FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('确认保存'))
                ]));
    return approved == true;
  }

  Widget choice(String title, List<String> values, String selected,
          void Function(String) onChanged) =>
      DropdownButtonFormField<String>(
          value: selected,
          isExpanded: true,
          decoration: InputDecoration(labelText: title),
          items: [
            for (final value in values)
              DropdownMenuItem(value: value, child: Text(catalogLabel(value)))
          ],
          onChanged: saving || retryDraft != null
              ? null
              : (value) {
                  if (value != null) setState(() => onChanged(value));
                });

  Widget field(String title, TextEditingController controller,
          {String? Function(String?)? validator, String? hint}) =>
      TextFormField(
          controller: controller,
          enabled: !saving && retryDraft == null,
          decoration: InputDecoration(labelText: title, helperText: hint),
          validator: validator ?? requiredText);

  Future<void> pickDate(bool start) async {
    final current = start ? starts : ends;
    final date = await showDatePicker(
        context: context,
        initialDate: current,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    final selected =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (start) {
        starts = selected;
      } else {
        ends = selected;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    final locked = saving || retryDraft != null;
    return AlertDialog(
        title: Text(widget.existing == null ? '创建报价草稿' : '修订报价草稿'),
        content: SizedBox(
            width: compact ? MediaQuery.sizeOf(context).width - 70 : 680,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Notice('这是内部草稿。批准后仍不可购买，也不会改变设备系统权限。'),
                          const SizedBox(height: 16),
                          Text('草稿编号 $id',
                              style:
                                  const TextStyle(color: muted, fontSize: 12)),
                          const SizedBox(height: 18),
                          const Text('产品与适用范围',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 12),
                          _grid(compact, [
                            field('SKU', sku,
                                validator: (v) => RegExp(r'^[A-Z0-9_]{1,80}$')
                                        .hasMatch(v?.trim().toUpperCase() ?? '')
                                    ? null
                                    : '使用大写字母、数字和下划线'),
                            field('SKU 版本', version,
                                validator: positiveInteger),
                            field('地区代码', region,
                                validator: (v) => RegExp(r'^[A-Z]{2}$')
                                        .hasMatch(v?.trim().toUpperCase() ?? '')
                                    ? null
                                    : '请输入两位地区代码，例如 CN'),
                            choice('渠道', catalogChannels, channel,
                                (v) => channel = v),
                            choice('客户类型', catalogBuyerKinds, buyerKind,
                                (v) => buyerKind = v),
                            choice('平台', catalogPlatforms, platform,
                                (v) => platform = v),
                            choice('设备模式', catalogDeviceModes, deviceMode,
                                (v) => deviceMode = v),
                            choice('计费周期', catalogBillingPeriods, period,
                                (v) => period = v)
                          ]),
                          const SizedBox(height: 20),
                          const Text('报价与容量',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 12),
                          _grid(compact, [
                            choice('价格类型', catalogPriceTypes, priceType, (v) {
                              priceType = v;
                              if (v == 'QUOTE') tax = 'QUOTE_REQUIRED';
                              if (v == 'FIXED' && tax == 'QUOTE_REQUIRED') {
                                tax = 'INCLUSIVE';
                              }
                            }),
                            field('币种代码', currency,
                                validator: (v) => RegExp(r'^[A-Z]{3}$')
                                        .hasMatch(v?.trim().toUpperCase() ?? '')
                                    ? null
                                    : '请输入三位币种代码，例如 CNY'),
                            if (priceType == 'FIXED')
                              field('价格（最小货币单位）', amount,
                                  validator: (v) =>
                                      positiveInteger(v, allowZero: true),
                                  hint: '例如 CNY 100 表示 1 元'),
                            if (priceType == 'FIXED')
                              choice('税费口径', const ['INCLUSIVE', 'EXCLUSIVE'],
                                  tax, (v) => tax = v),
                            choice('名额类型', catalogCapacityKinds, capacityKind,
                                (v) => capacityKind = v),
                            field('设备名额', capacity,
                                validator: (v) => positiveInteger(v,
                                    allowZero: capacityKind == 'ADD_ON'))
                          ]),
                          const SizedBox(height: 20),
                          const Text('功能与时间',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                          for (final feature in catalogFeatures)
                            CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(catalogLabel(feature)),
                                value: features.contains(feature),
                                onChanged: locked
                                    ? null
                                    : (checked) => setState(() {
                                          if (checked == true) {
                                            features.add(feature);
                                          } else {
                                            features.remove(feature);
                                          }
                                        })),
                          const SizedBox(height: 8),
                          _grid(compact, [
                            _dateButton(
                                '生效时间', starts, !locked, () => pickDate(true)),
                            _dateButton(
                                '到期时间', ends, !locked, () => pickDate(false))
                          ]),
                          if (error != null) ...[
                            const SizedBox(height: 16),
                            FailureView(error!),
                          ],
                          if (retryDraft != null) ...[
                            const SizedBox(height: 12),
                            const Notice(
                                '上次结果尚未确认。可用相同草稿编号和内容重试；若要更改字段，请关闭并刷新目录后重新打开。',
                                warning: true),
                          ]
                        ])))),
        actions: [
          TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(),
              child: const Text('关闭')),
          FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving
                  ? '保存中…'
                  : retryDraft != null
                      ? '用原内容重试'
                      : widget.existing == null
                          ? '创建草稿'
                          : '保存修订'))
        ]);
  }

  Widget _grid(bool compact, List<Widget> children) =>
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final child in children)
          SizedBox(width: compact ? double.infinity : 320, child: child)
      ]);

  Widget _dateButton(
          String title, DateTime value, bool enabled, VoidCallback select) =>
      OutlinedButton.icon(
          onPressed: enabled ? select : null,
          icon: const Icon(Icons.calendar_month_outlined),
          label:
              Text('$title：${DateFormat('yyyy-MM-dd HH:mm').format(value)}'));
}

const _previewLabels = <String, String>{
  'sku': '产品编号',
  'skuVersion': '产品版本',
  'region': '地区',
  'channel': '渠道',
  'buyerKind': '客户类型',
  'platform': '平台',
  'deviceMode': '设备模式',
  'billingPeriod': '计费周期',
  'priceType': '价格类型',
  'currency': '币种',
  'priceMinor': '价格（最小货币单位）',
  'taxBasis': '税费口径',
  'capacityKind': '名额类型',
  'deviceCapacity': '设备名额',
  'features': '功能',
  'availableFrom': '生效时间',
  'availableUntil': '到期时间'
};

String catalogLabel(String code) =>
    const {
      'DRAFT': '草稿',
      'IN_REVIEW': '待审核',
      'APPROVED': '已审核',
      'RETIRED': '已下架',
      'CREATED': '创建',
      'REVISED': '修订',
      'SUBMITTED': '提交审核',
      'GOOGLE_PLAY': 'Google Play',
      'APP_STORE': 'App Store',
      'CONTRACT': '合同',
      'PRIVATE_LICENSE': '私有许可',
      'FAMILY': '家庭',
      'ORGANIZATION': '机构',
      'ANDROID': 'Android 手机/平板',
      'ANDROID_TV': 'Android TV',
      'IOS': 'iOS',
      'WINDOWS': 'Windows',
      'MACOS': 'macOS',
      'BYOD': '家庭自有设备',
      'WORK_PROFILE': '工作资料模式',
      'FULLY_MANAGED': '完全受管设备',
      'DEDICATED': '专用设备',
      'MONTH': '月付',
      'YEAR': '年付',
      'ONE_TIME': '一次性',
      'FIXED': '固定价',
      'QUOTE': '人工报价',
      'INCLUSIVE': '含税',
      'EXCLUSIVE': '未税',
      'QUOTE_REQUIRED': '报价时确认',
      'BASE': '基础名额',
      'ADD_ON': '加购名额',
      'ADVANCED_SCHEDULES': '精细时间计划',
      'WEB_FILTERING': '网站分类管理',
      'MANAGED_ANDROID': '受管 Android 功能权益',
      'ORG_BULK': '机构批量管理',
      'AI_INSIGHTS': '智能使用建议'
    }[code] ??
    code;
