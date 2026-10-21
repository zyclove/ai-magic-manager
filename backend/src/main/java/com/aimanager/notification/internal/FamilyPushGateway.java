package com.aimanager.notification.internal;

/** Provider acceptance is never a device receipt. Stable deliveryId correlates every retry. */
interface FamilyPushGateway {
  boolean available();
  Accepted send(Command command);
  record Command(String deliveryId,String token,String eventId,String installationId,String title,String body,String deepLink) {}
  record Accepted(String providerMessageId) {
    public Accepted {
      if (providerMessageId==null || !providerMessageId.matches("[A-Za-z0-9_-]{1,128}"))
        throw new Failure("PROVIDER_RESPONSE_INVALID",true);
    }
  }
  final class Failure extends RuntimeException {
    final boolean retryable;
    Failure(String code,boolean retryable) { super(code); this.retryable=retryable; }
  }
}
