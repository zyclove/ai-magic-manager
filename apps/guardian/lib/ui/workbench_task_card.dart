import 'package:flutter/material.dart';
import '../core/overview_attention.dart';
import 'design.dart';

/// One visible next step. The host rechecks the captured scope before acting.
class WorkbenchTaskCard extends StatelessWidget {
  final String title, description, label;
  final IconData icon;
  final bool urgent, busy;
  final VoidCallback onPressed;
  final Key buttonKey;

  const WorkbenchTaskCard({super.key,
      required this.title, required this.description, required this.label,
      required this.icon, required this.onPressed,
      this.urgent = false, this.busy = false,
      this.buttonKey = const Key('workbench-next-action')});

  factory WorkbenchTaskCard.attention(OverviewAttention value,
      {Key? key, required VoidCallback onPressed, bool busy = false,
      Key buttonKey = const Key('workbench-next-action')}) => WorkbenchTaskCard(
          key: key, title: value.title, description: value.description,
          label: value.label, urgent: value.urgent, busy: busy,
          onPressed: onPressed, buttonKey: buttonKey,
          icon: switch (value.kind) {
            OverviewAttentionKind.help => Icons.volunteer_activism_outlined,
            OverviewAttentionKind.requests => Icons.task_alt_outlined,
            OverviewAttentionKind.connection => Icons.wifi_off_outlined,
          });

  @override
  Widget build(BuildContext context) => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon,
              size: 24, color: urgent ? const Color(0xFFA7473C) : navy),
          const SizedBox(width: 10),
          Expanded(
              child: Text(urgent ? '需要优先关注' : '接下来可以做',
                  style: TextStyle(
                      color: urgent ? const Color(0xFFA7473C) : muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(description,
            style: const TextStyle(color: muted, height: 1.7)),
        const SizedBox(height: 18),
        Semantics(
            liveRegion: busy,
            child: FilledButton.icon(
                key: buttonKey,
                onPressed: busy ? null : onPressed,
                icon: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))
                    : const Icon(Icons.arrow_forward, size: 18),
                label: Text(busy ? '处理中…' : label,
                    textAlign: TextAlign.center))),
      ]));
}
