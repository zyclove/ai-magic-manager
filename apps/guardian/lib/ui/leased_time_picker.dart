import 'package:flutter/material.dart';

import 'leased_dialog.dart';

/// Keeps stock time-picker navigation inside the original route/access lease.
Future<TimeOfDay?> pickLeasedTime(BuildContext context,
    {required TimeOfDay initialTime,
    required String helpText,
    required Listenable accessChanges,
    required bool Function() hasAccess}) =>
    leasedDialog<TimeOfDay>(context,
        accessChanges: accessChanges,
        hasAccess: hasAccess,
        builder: (dialog, route, access) => MediaQuery(
            data: MediaQuery.of(dialog).copyWith(alwaysUse24HourFormat: true),
            child: Navigator(
                pages: [
                  MaterialPage<TimeOfDay>(
                      child: TimePickerDialog(
                          initialTime: initialTime,
                          initialEntryMode: TimePickerEntryMode.input,
                          helpText: helpText,
                          cancelText: '取消',
                          confirmText: '确定',
                          hourLabelText: '时',
                          minuteLabelText: '分',
                          errorInvalidText: '请输入有效时间')),
                ],
                // Keep the stock picker's Navigator.pop local to this lease.
                onPopPage: (_, result) {
                  if (access.permitted() &&
                      route.available &&
                      route.isCurrent) {
                    route.finish(result is TimeOfDay ? result : null);
                  }
                  return false;
                })));
