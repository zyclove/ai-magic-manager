import 'package:flutter/material.dart';

const navy = Color(0xFF19335C);
const line = Color(0xFFE2E8F0);
const canvas = Color(0xFFF5F7FB);

String label(String? value) =>
    const {
      'ALLOW': '允许',
      'DENY': '禁止',
      'PROTECT': '保护',
      'GRANT': '授予',
      'DEFAULT': '系统默认',
      'LIMIT': '限制',
      'REMIND': '提醒',
      'APP_LAUNCH': '应用启动',
      'APP_INSTALL': '应用安装',
      'APP_UNINSTALL': '应用卸载',
      'RUNTIME_PERMISSION': '运行时权限',
      'SPECIAL_ACCESS': '特殊访问权限',
      'DAILY_QUOTA': '每日额度',
      'TIME_WINDOW': '使用时段',
      'DOMAIN_ACCESS': '域名访问',
      'USAGE_REMINDER': '使用提醒',
      'PRIMARY': '主空间',
      'WORK': '工作空间',
      'SECONDARY': '次要空间',
      'UNKNOWN': '未知',
    }[value] ??
    '尚未确认';
