import 'package:device_policy/device_policy.dart';
import 'models.dart';

/// 独占此 transport 的生命周期。复用设备身份、TLS、限长、超时及拒绝重定向。
class ObservationHttpApi implements ObservationApi {
  final DeviceConfigurationTransport transport;
  ObservationHttpApi(this.transport);
  @override
  Future<Map<String, dynamic>> settings() =>
      transport.observe(DeviceObservationOperation.settings);
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body) =>
      transport.observe(DeviceObservationOperation.inventory, body: body);
  @override
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body) =>
      transport.observe(DeviceObservationOperation.usage, body: body);
  @override
  void close() => transport.close();
}
