package com.aimanager.commerce.internal;

import com.fasterxml.jackson.databind.JsonNode;
import java.net.URI;
import java.time.LocalDate;
import java.util.Set;

/** 复用支付商户签名与平台公钥，不重新读取或复制任何密钥。 */
final class FamilyWechatBillGateway implements FamilyBillGateway {
  private final FamilyWechatV3Gateway payment;
  FamilyWechatBillGateway(FamilyWechatV3Gateway payment) { this.payment = payment; }
  @Override public boolean available() { return payment.verificationAvailable(); }
  @Override public String merchantId() { return payment.billMerchantId(); }
  @Override public String appId() { return payment.billAppId(); }

  @Override public BillFile download(LocalDate date) {
    if (date == null || !available()) throw new Unavailable("BILL_PROVIDER_UNAVAILABLE");
    JsonNode metadata = payment.signedBillRead("/v3/bill/tradebill?bill_date=" + date + "&bill_type=ALL");
    if (metadata == null || !metadata.isObject() || !"SHA1".equals(text(metadata,"hash_type"))) throw invalid();
    String hash = text(metadata,"hash_value"), address = text(metadata,"download_url");
    if (!hash.matches("[a-fA-F0-9]{40}") || address.length() > 2048) throw invalid();
    URI uri;
    try { uri = URI.create(address); }
    catch (IllegalArgumentException malformed) { throw invalid(); }
    if (!"https".equals(uri.getScheme()) || !"api.mch.weixin.qq.com".equals(uri.getHost()) || uri.getUserInfo() != null
        || uri.getFragment() != null || uri.getPort() != -1 && uri.getPort() != 443
        || !Set.of("/v3/billdownload/file", "/v3/bill/downloadurl").contains(uri.getRawPath())
        || uri.getRawQuery() == null || !uri.getRawQuery().matches("token=[A-Za-z0-9_%+\\-=.]{1,1900}")) throw invalid();
    byte[] bytes = payment.downloadBill(uri, FamilyTradeBillParser.MAX_BYTES);
    if (bytes == null || bytes.length == 0 || bytes.length > FamilyTradeBillParser.MAX_BYTES || !FamilyBillGateway.sha1(bytes).equalsIgnoreCase(hash)) throw invalid();
    return new BillFile(bytes, hash);
  }
  private static String text(JsonNode parent, String name) {
    JsonNode value = parent.path(name);
    if (!value.isTextual() || value.asText().isBlank()) throw invalid();
    return value.asText();
  }
  private static FamilyTradeBillParser.InvalidBill invalid() { return new FamilyTradeBillParser.InvalidBill(); }
}
