import 'package:flutter/material.dart';

/// Validates locally without dismissing the dialog or losing other fields.
/// Server authentication, authorization and version checks remain authoritative.
class ManagedEnrollmentForm extends StatefulWidget {
  final bool binding;
  const ManagedEnrollmentForm({super.key, required this.binding});

  @override
  State<ManagedEnrollmentForm> createState() => _ManagedEnrollmentFormState();
}

class _ManagedEnrollmentFormState extends State<ManagedEnrollmentForm> {
  final form = GlobalKey<FormState>();
  final identifier = TextEditingController();
  final contract = TextEditingController();

  @override
  void dispose() {
    identifier.dispose();
    contract.dispose();
    super.dispose();
  }

  void submit() {
    if (form.currentState!.validate()) {
      Navigator.pop(context,
          (id: identifier.text.trim(), contract: contract.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(widget.binding ? '申请机构审核' : '核对设备身份'),
        content: SizedBox(
            width: 480,
            child: Form(
                key: form,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.binding
                          ? '填写机构提供的企业资源 ID 和已生效合同编号，提交后由平台独立审核。'
                          : '从受管提供方的设备详情中取得设备 ID。核对注册身份不会自动启用应用限制。'),
                      const SizedBox(height: 16),
                      TextFormField(
                          controller: identifier,
                          autofocus: true,
                          maxLength: 128,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: widget.binding
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted:
                              widget.binding ? null : (_) => submit(),
                          decoration: InputDecoration(
                              labelText:
                                  widget.binding ? '企业资源 ID' : '提供方设备 ID',
                              helperText: '仅填写 ID，不粘贴完整网址',
                              helperMaxLines: 2),
                          validator: (value) =>
                              RegExp(r'^[A-Za-z0-9_-]{1,128}$')
                                      .hasMatch(value?.trim() ?? '')
                                  ? null
                                  : '请输入 1–128 位字母、数字、下划线或短横线'),
                      if (widget.binding) ...[
                        const SizedBox(height: 8),
                        TextFormField(
                            controller: contract,
                            maxLength: 200,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => submit(),
                            decoration:
                                const InputDecoration(labelText: '合同编号'),
                            validator: (value) =>
                                (value?.trim().isEmpty ?? true)
                                    ? '请填写已生效的合同编号'
                                    : null),
                      ],
                    ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: submit, child: Text(widget.binding ? '提交审核' : '核对身份')),
        ],
      );
}
