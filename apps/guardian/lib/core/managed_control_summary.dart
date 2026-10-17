/// Read-only presentation of exact operations returned by reviewed evidence.
/// Parsing this summary grants no permission and cannot initiate execution.
class ManagedControlSummary {
  final List<ManagedControlOperationDisplay> operations;
  ManagedControlSummary._(Iterable<ManagedControlOperationDisplay> operations)
      : operations = List.unmodifiable(operations);

  static ManagedControlSummary? parse(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 128) return null;
    final result = <ManagedControlOperationDisplay>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map ||
          item.length != 3 ||
          !item.containsKey('kind') ||
          !item.containsKey('effect') ||
          !item.containsKey('permission')) {
        return null;
      }
      final kind = item['kind'], effect = item['effect'];
      final permission = item['permission'];
      if (kind is! String || effect is! String) return null;
      if (kind == 'APP_LAUNCH' || kind == 'APP_INSTALL') {
        if (permission != null || (effect != 'ALLOW' && effect != 'DENY')) {
          return null;
        }
      } else if (kind == 'RUNTIME_PERMISSION') {
        if (permission is! String ||
            !_permissionNames.containsKey(permission) ||
            (effect != 'DENY' && effect != 'DEFAULT')) {
          return null;
        }
      } else {
        return null;
      }
      final key = '$kind:$effect:${permission ?? ''}';
      if (!seen.add(key)) return null;
      result.add(ManagedControlOperationDisplay._(
          kind, effect, permission as String?, key));
    }
    result.sort((a, b) => a._sortKey.compareTo(b._sortKey));
    return ManagedControlSummary._(result);
  }
}

class ManagedControlOperationDisplay {
  final String kind, effect;
  final String? permission;
  final String _sortKey;
  const ManagedControlOperationDisplay._(
      this.kind, this.effect, this.permission, this._sortKey);

  String get label {
    final action = effect == 'DEFAULT'
        ? '恢复用户询问'
        : effect == 'DENY'
            ? '禁止'
            : '允许';
    return switch (kind) {
      'APP_INSTALL' => '应用安装 · $action',
      'APP_LAUNCH' => '应用启动 · $action',
      _ =>
        '${_permissionNames[permission]} · ${permission!.substring(19)} · $action',
    };
  }
}

// This is a display catalog, not an authorization catalog. It mirrors the
// server's explicit AndroidRuntimePermissions names() vocabulary. The editor's
// selectable permission list is deliberately not changed by this presentation.
const _permissionNames = <String, String>{
  'android.permission.CAMERA': '相机',
  'android.permission.RECORD_AUDIO': '麦克风',
  'android.permission.READ_CONTACTS': '读取联系人',
  'android.permission.WRITE_CONTACTS': '修改联系人',
  'android.permission.GET_ACCOUNTS': '读取账号列表',
  'android.permission.READ_CALENDAR': '读取日历',
  'android.permission.WRITE_CALENDAR': '修改日历',
  'android.permission.ACCESS_COARSE_LOCATION': '大致位置',
  'android.permission.ACCESS_FINE_LOCATION': '精确位置',
  'android.permission.ACCESS_BACKGROUND_LOCATION': '后台位置',
  'android.permission.POST_NOTIFICATIONS': '发送通知',
  'android.permission.READ_MEDIA_IMAGES': '读取图片',
  'android.permission.READ_MEDIA_VIDEO': '读取视频',
  'android.permission.READ_MEDIA_AUDIO': '读取音频',
  'android.permission.READ_MEDIA_VISUAL_USER_SELECTED': '读取所选图片与视频',
  'android.permission.READ_EXTERNAL_STORAGE': '读取共享存储',
  'android.permission.WRITE_EXTERNAL_STORAGE': '修改共享存储',
  'android.permission.BLUETOOTH_SCAN': '扫描蓝牙设备',
  'android.permission.BLUETOOTH_CONNECT': '连接蓝牙设备',
  'android.permission.BLUETOOTH_ADVERTISE': '蓝牙广播',
  'android.permission.NEARBY_WIFI_DEVICES': '附近 Wi-Fi 设备',
  'android.permission.BODY_SENSORS': '身体传感器',
  'android.permission.BODY_SENSORS_BACKGROUND': '后台身体传感器',
  'android.permission.READ_PHONE_STATE': '读取电话状态',
  'android.permission.READ_PHONE_NUMBERS': '读取电话号码',
  'android.permission.CALL_PHONE': '拨打电话',
  'android.permission.ANSWER_PHONE_CALLS': '接听电话',
  'android.permission.ADD_VOICEMAIL': '添加语音留言',
  'android.permission.USE_SIP': '互联网电话',
  'android.permission.PROCESS_OUTGOING_CALLS': '处理拨出电话',
  'android.permission.ACTIVITY_RECOGNITION': '活动识别',
  'android.permission.READ_SMS': '读取短信',
  'android.permission.SEND_SMS': '发送短信',
  'android.permission.RECEIVE_SMS': '接收短信',
  'android.permission.RECEIVE_MMS': '接收彩信',
  'android.permission.RECEIVE_WAP_PUSH': '接收网络推送消息',
  'android.permission.READ_CALL_LOG': '读取通话记录',
  'android.permission.WRITE_CALL_LOG': '修改通话记录',
  'android.permission.UWB_RANGING': '超宽带测距',
};
