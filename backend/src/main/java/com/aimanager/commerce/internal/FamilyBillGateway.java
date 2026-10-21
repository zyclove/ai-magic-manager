package com.aimanager.commerce.internal;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.util.HexFormat;

/** 仅服务端：申请响应必须验签，文件必须匹配该响应的官方摘要。 */
interface FamilyBillGateway {
  boolean available();
  String merchantId();
  String appId();
  BillFile download(LocalDate billDate);
  record BillFile(byte[] bytes, String sha1) {
    public BillFile { bytes = bytes == null ? null : bytes.clone(); }
    @Override public byte[] bytes() { return bytes == null ? null : bytes.clone(); }
  }
  static String sha1(byte[] bytes) {
    try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(bytes)); }
    catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException("SHA-1 unavailable", impossible); }
  }
  final class Unavailable extends RuntimeException {
    private final String code;
    Unavailable(String code) { super("FAMILY_BILL_UNAVAILABLE"); this.code = code == null ? "BILL_PROVIDER_UNAVAILABLE" : code; }
    String code() { return code; }
  }
}
