package com.aimanager.commerce.internal;

import java.util.Map;

/**
 * Server-only payment trust boundary. A certified adapter must verify WeChat v3 response and
 * notification signatures, decrypt notifications, bind app/merchant IDs and query authoritative
 * transaction/refund state. Client SDK completion is never evidence of payment.
 */
interface FamilyPaymentGateway {
  boolean available();
  default boolean verificationAvailable() { return available(); }
  default boolean refundsAvailable() { return available(); }
  AppPayment createAppPayment(PaymentCommand command);
  PaymentEvidence queryPayment(String merchantOrderId);
  /** 关单应答仅为请求结果；调用方仍须查单取得 CLOSED 事实。 */
  default void closePayment(String merchantOrderId) { throw FamilyCommerceConfiguration.unavailable(); }
  Notification verifyNotification(Map<String, String> headers, String rawBody);
  void submitRefund(RefundCommand command);
  RefundEvidence queryRefund(String merchantRefundId);

  record PaymentCommand(String merchantOrderId, int priceMinor, String currency,
      String description, long expiresAt) {}
  record AppPayment(Map<String, String> parameters) {
    public AppPayment { parameters = Map.copyOf(parameters); }
  }
  record PaymentEvidence(String merchantOrderId, String providerTransactionId,
      Integer priceMinor, String currency, String tradeState, long paidAt, String evidenceHash) {}
  record RefundCommand(String merchantRefundId, String merchantOrderId,
      String providerTransactionId, int priceMinor, String currency, String reason) {}
  record RefundEvidence(String merchantRefundId, String merchantOrderId,
      String providerRefundId, String providerTransactionId, int priceMinor,
      String currency, String refundState, long refundedAt, String evidenceHash,Long acceptedAt) {
    RefundEvidence(String merchantRefundId,String merchantOrderId,String providerRefundId,String providerTransactionId,
        int priceMinor,String currency,String refundState,long refundedAt,String evidenceHash) {
      this(merchantRefundId,merchantOrderId,providerRefundId,providerTransactionId,priceMinor,currency,refundState,refundedAt,evidenceHash,null);
    }
  }
  /** 只有通过平台签名验证的不存在应答才能触发原退款号重试。 */
  final class ResourceMissing extends RuntimeException {
    ResourceMissing(){super("WECHAT_PROVIDER_RESOURCE_NOT_EXISTS");}
  }
  record Notification(String eventId, String eventType, String evidenceHash,
      PaymentEvidence payment, RefundEvidence refund) {}
}
