/// Display names shared with the rule editor. These maps do not authorize a
/// permission or replace the server's runtime permission catalog validation.
const runtimePermissionNames = <String, String>{
  'CAMERA': '相机',
  'RECORD_AUDIO': '麦克风',
  'ACCESS_FINE_LOCATION': '精确位置',
  'ACCESS_COARSE_LOCATION': '大致位置',
  'ACCESS_BACKGROUND_LOCATION': '后台位置',
  'READ_CONTACTS': '读取联系人',
  'READ_CALENDAR': '读取日历',
  'POST_NOTIFICATIONS': '发送通知',
};

const specialAccessNames = <String, String>{
  'USAGE_ACCESS': '使用情况访问',
  'OVERLAY': '悬浮窗',
  'NOTIFICATION_ACCESS': '通知读取',
  'ACCESSIBILITY': '无障碍服务',
  'VPN': 'VPN 连接',
};

String? runtimePermissionDisplayLabel(String permission) {
  const prefix = 'android.permission.';
  if (!permission.startsWith(prefix)) return null;
  final short = permission.substring(prefix.length);
  final name = runtimePermissionNames[short];
  return name == null ? null : '$name · $short';
}
