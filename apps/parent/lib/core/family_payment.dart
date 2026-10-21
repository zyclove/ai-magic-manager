import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

/// The native SDK only dispatches a request. All payment facts come from the API.
class NativeFamilyPay {
  final MethodChannel channel;
  final bool Function() available;
  NativeFamilyPay(
      {this.channel = const MethodChannel('com.aimanager.parent/wechat_pay'),
      bool Function()? available})
      : available = available ??
            (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  Future<void> launch(
      {required String attemptId, required Json parameters}) async {
    if (!available()) {
      throw const ParentApiException(503, 'WECHAT_PAY_PLATFORM_UNAVAILABLE');
    }
    final fields = [
      'appId',
      'partnerId',
      'prepayId',
      'packageValue',
      'nonceStr',
      'timeStamp',
      'sign'
    ];
    if (attemptId.isEmpty ||
        fields.any((k) =>
            parameters[k] is! String || (parameters[k] as String).isEmpty) ||
        !RegExp(r'^wx[0-9a-fA-F]{16}$').hasMatch(parameters['appId']) ||
        !RegExp(r'^[0-9]{5,20}$').hasMatch(parameters['partnerId']) ||
        parameters['packageValue'] != 'Sign=WXPay' ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(parameters['prepayId']) ||
        !RegExp(r'^[A-Za-z0-9]{1,32}$').hasMatch(parameters['nonceStr']) ||
        !RegExp(r'^[0-9]{10}$').hasMatch(parameters['timeStamp']) ||
        !RegExp(r'^[A-Za-z0-9+/=]{1,2048}$').hasMatch(parameters['sign'])) {
      throw const ParentApiException(502, 'INVALID_PAYMENT_PARAMETERS');
    }
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
          'launch', {'attemptId': attemptId, 'parameters': parameters});
      if (value?['status'] != 'DISPATCHED') {
        throw const ParentApiException(503, 'WECHAT_PAY_DISPATCH_FAILED');
      }
    } on MissingPluginException {
      throw const ParentApiException(503, 'WECHAT_PAY_PLATFORM_UNAVAILABLE');
    } on PlatformException catch (error) {
      throw ParentApiException(503, error.code);
    }
  }

  Future<void> clear(String attemptId) async {
    if (!available()) return;
    try {
      await channel.invokeMethod<bool>('clear', {'attemptId': attemptId});
    } on PlatformException {
      /* Server confirmation remains authoritative. */
    } on MissingPluginException {
      /* Reference cleanup is best effort outside Android. */
    }
  }
}

/// Saves operation references before any order POST or native app switch.
/// No SDK payload, signature, token, phone or child's data is persisted here.
class FamilyPaymentCoordinator {
  final FamilyService service;
  final String actor;
  final ParentDurableStorage storage;
  final NativeFamilyPay native;
  Json? pending;
  bool loaded = false, busy = false;
  FamilyPaymentCoordinator(
      {required this.service,
      required this.actor,
      ParentDurableStorage? storage,
      NativeFamilyPay? native})
      : storage = storage ?? ParentDurableStorage(),
        native = native ?? NativeFamilyPay();
  String get key => 'parent.family.payment.${service.tenantId}.$actor';
  String? get pendingOrderId => pending?['orderId'] as String?;
  String? get pendingPlanKey => pending?['planKey'] as String?;
  bool canLaunchOrder(String orderId) =>
      loaded && !busy && (pending == null || pendingOrderId == orderId);
  Future<void> restore() async {
    service.check();
    final raw = await storage.read(key: key);
    service.check();
    if (raw != null) {
      if (raw.length > 4096) {
        throw const ParentApiException(502, 'INVALID_PAYMENT_RECOVERY');
      }
      final value = jsonDecode(raw);
      if (value is! Json ||
          value['createdAt'] is! int ||
          (value['orderId'] == null &&
              (value['orderKey'] is! String ||
                  !const {'FAMILY_MONTH', 'FAMILY_YEAR'}
                      .contains(value['planKey']))) ||
          (value['orderId'] != null &&
              (value['orderId'] is! String || value['orderId'].isEmpty)) ||
          (value['attemptId'] != null && value['attemptId'] is! String)) {
        throw const ParentApiException(502, 'INVALID_PAYMENT_RECOVERY');
      }
      pending = value;
    }
    loaded = true;
  }

  Future<void> _save(Json value) async {
    service.check();
    await storage.write(key: key, value: jsonEncode(value));
    service.check();
    pending = value;
  }

  Future<Json> createOrder(String planKey, {int offerVersion = 1}) async {
    service.check();
    if (!loaded || busy) throw StateError('请先核对原支付进度。');
    if (pendingOrderId != null ||
        pendingPlanKey != null && pendingPlanKey != planKey) {
      throw StateError('请先核对原订单，避免重复创建。');
    }
    busy = true;
    try {
      if (pending == null) {
        await _save({
          'orderKey': const Uuid().v4(),
          'planKey': planKey,
          'offerVersion': offerVersion,
          'createdAt': DateTime.now().millisecondsSinceEpoch
        });
      }
      final value = await service.write('POST', '/orders',
          body: {
            'planKey': pending!['planKey'],
            'offerVersion': pending!['offerVersion'] ?? 1
          },
          idempotencyKey: pending!['orderKey']);
      if (value['id'] is! String || value['tenantId'] != service.tenantId) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      await _save({...pending!, 'orderId': value['id']});
      return value;
    } on ParentApiException catch (error) {
      // The server rejects this quotation before creating an order. Unknown
      // transport outcomes keep the durable original key and body instead.
      if (error.code == 'FAMILY_OFFER_CHANGED' && pendingOrderId == null) {
        await storage.delete(key: key);
        service.check();
        pending = null;
      }
      rethrow;
    } finally {
      busy = false;
    }
  }

  Future<void> launch(String orderId, {bool Function()? allowLaunch}) async {
    void checkLaunch() {
      service.check();
      if (allowLaunch != null && !allowLaunch()) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
    }

    checkLaunch();
    if (!loaded || busy) throw StateError('请先核对原支付进度。');
    if (!canLaunchOrder(orderId)) {
      throw StateError('请先核对原订单，避免重复支付。');
    }
    busy = true;
    try {
      await _save({
        ...?pending,
        'orderId': orderId,
        'attemptKey': pending?['attemptKey'] ?? const Uuid().v4(),
        'createdAt':
            pending?['createdAt'] ?? DateTime.now().millisecondsSinceEpoch
      });
      checkLaunch();
      final attempt = await service.write(
          'POST', '/orders/${Uri.encodeComponent(orderId)}/payment-attempts',
          body: {}, idempotencyKey: pending!['attemptKey']);
      if (attempt['id'] is! String ||
          attempt['orderId'] != orderId ||
          !const {'READY', 'INITIATED'}.contains(attempt['status']) ||
          attempt['parameters'] is! Json) {
        throw const ParentApiException(502, 'INVALID_PAYMENT_PARAMETERS');
      }
      checkLaunch();
      await _save({...pending!, 'attemptId': attempt['id']});
      checkLaunch();
      await native.launch(
          attemptId: attempt['id'], parameters: attempt['parameters']);
      // DISPATCHED deliberately leaves the durable order pending.
    } finally {
      busy = false;
    }
  }

  /// An already-authorized order GET can finish local payment recovery.
  /// Refreshing an order does not create a new verification operation.
  Future<void> reconcile(Json order) async {
    service.check();
    if (!loaded ||
        pendingOrderId == null ||
        order['id'] != pendingOrderId ||
        order['tenantId'] != service.tenantId) return;
    if (!const {'PAID', 'REFUNDED', 'CLOSED', 'EXPIRED', 'CANCELLED'}
        .contains(order['status'])) return;
    final raw = await storage.read(key: key);
    service.check();
    final saved = raw == null ? null : jsonDecode(raw);
    if (saved is! Json || saved['orderId'] != order['id']) return;
    final attemptId = saved['attemptId'] as String?;
    await storage.delete(key: key);
    service.check();
    pending = null;
    if (attemptId != null) await native.clear(attemptId);
  }

  Future<Json?> verify() async {
    service.check();
    if (!loaded || busy || pendingOrderId == null) return null;
    busy = true;
    try {
      final orderId = pendingOrderId!;
      Object? verificationFailure;
      try {
        await service.write('POST',
            '/orders/${Uri.encodeComponent(orderId)}/payment-verifications',
            body: {});
      } catch (error) {
        verificationFailure = error;
      }
      final order =
          await service.object('/orders/${Uri.encodeComponent(orderId)}');
      if (order['id'] != orderId ||
          order['tenantId'] != service.tenantId ||
          order['status'] is! String) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (const {'PAID', 'REFUNDED', 'CLOSED', 'EXPIRED', 'CANCELLED'}
          .contains(order['status'])) {
        await reconcile(order);
      } else if (verificationFailure != null) {
        throw verificationFailure;
      }
      return order;
    } finally {
      busy = false;
    }
  }
}
