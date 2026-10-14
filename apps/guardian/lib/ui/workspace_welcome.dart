import 'package:flutter/material.dart';
import 'design.dart';

class WorkspaceWelcome extends StatelessWidget {
  final VoidCallback? onCreate;
  final VoidCallback onJoin;
  final List<Widget> platformTools;
  const WorkspaceWelcome(
      {super.key,
      this.onCreate,
      required this.onJoin,
      this.platformTools = const []});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading(onCreate == null ? '加入你的工作空间' : '从一个工作空间开始',
            '集中管理家庭或机构的档案、设备和使用规则。'),
        LayoutBuilder(builder: (context, box) {
          final paired = onCreate != null && box.maxWidth >= 700;
          final width = paired ? (box.maxWidth - 16) / 2 : box.maxWidth;
          return Wrap(spacing: 16, runSpacing: 16, children: [
            if (onCreate != null)
              SizedBox(
                  width: width,
                  child: _choice(context,
                      icon: Icons.add_home_outlined,
                      title: '管理自己的家庭或机构',
                      description: '先起一个名称，之后再添加档案和连接设备。',
                      action: FilledButton.icon(
                          onPressed: onCreate,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('创建工作空间')))),
            SizedBox(
                width: width,
                child: _choice(context,
                    icon: Icons.group_add_outlined,
                    title: '加入已有工作空间',
                    description: '已有邀请？使用管理员发来的邀请加入，无需重复创建。',
                    action: OutlinedButton.icon(
                        onPressed: onJoin,
                        icon: const Icon(Icons.mail_outline, size: 18),
                        label: const Text('使用邀请加入')))),
          ]);
        }),
        if (platformTools.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text('平台工具',
              style: TextStyle(
                  color: muted, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: platformTools),
        ],
      ]);

  Widget _choice(BuildContext context,
          {required IconData icon,
          required String title,
          required String description,
          required Widget action}) =>
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: canvas, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 26, color: navy)),
        const SizedBox(height: 20),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(color: muted, height: 1.7)),
        const SizedBox(height: 24),
        action,
      ]));
}
