package com.aimanager.commerce.internal;

import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.format.ResolverStyle;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** 微信现代 ALL 交易账单：未知格式明确失败，不猜测旧版金额或退款成功日。 */
final class FamilyTradeBillParser {
  static final int MAX_BYTES = 8 * 1024 * 1024;
  static final int MAX_ROWS = 20_000;
  private static final int MAX_LINE = 16_384;
  private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");
  private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("uuuu-MM-dd HH:mm:ss")
      .withResolverStyle(ResolverStyle.STRICT);
  private static final List<String> HEADER = List.of("交易时间", "公众账号ID", "商户号", "特约商户号", "设备号",
      "微信订单号", "商户订单号", "用户标识", "交易类型", "交易状态", "付款银行", "货币种类", "应结订单金额", "代金券金额",
      "微信退款单号", "商户退款单号", "退款金额", "充值券退款金额", "退款类型", "退款状态", "商品名称", "商户数据包",
      "手续费", "费率", "订单金额", "申请退款金额", "费率备注");
  private static final String FOOTER = "总交易单数,应结订单总金额,退款总金额,充值券退款总金额,手续费总金额,订单总金额,申请退款总金额";
  private FamilyTradeBillParser() {}

  static Bill parse(byte[] bytes, LocalDate day) {
    if (bytes == null || bytes.length == 0 || bytes.length > MAX_BYTES || day == null) throw invalid();
    String text;
    try {
      text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
    } catch (CharacterCodingException malformed) { throw invalid(); }
    if (text.startsWith("\ufeff")) text = text.substring(1);
    String[] lines = text.split("\r?\n", -1);
    if (lines.length < 3 || !Arrays.asList(lines[0].split(",", -1)).equals(HEADER)) throw invalid();
    var rows = new ArrayList<Row>();
    long[] sums = new long[6];
    int at = 1;
    for (; at < lines.length && !FOOTER.equals(lines[at]); at++) {
      String line = lines[at];
      if (line.length() > MAX_LINE || line.isEmpty() || rows.size() == MAX_ROWS) throw invalid();
      String[] values = fields(line, HEADER.size());
      long settlement = money(values[12], false), refundSettlement = money(values[16], false);
      long couponRefund = money(values[17], false), fee = money(values[22], true);
      long order = money(values[24], false), refund = money(values[25], false);
      // 其余金额也必须是精确分，避免可疑账单利用不参与汇总的列绕过校验。
      money(values[13], false);
      long[] amount = {settlement, refundSettlement, couponRefund, fee, order, refund};
      try { for (int index = 0; index < amount.length; index++) sums[index] = Math.addExact(sums[index], amount[index]); }
      catch (ArithmeticException overflow) { throw invalid(); }
      long occurredAt;
      try { occurredAt = LocalDateTime.parse(values[0], TIME).atZone(ZONE).toInstant().toEpochMilli(); }
      catch (java.time.DateTimeException malformed) { throw invalid(); }
      for (int index : new int[] {1, 2, 3, 5, 6, 8, 9, 11, 14, 15, 18, 19}) {
        if (values[index].length() > 128 || values[index].chars().anyMatch(Character::isISOControl)) throw invalid();
      }
      if (!List.of("SUCCESS", "REFUND", "REVOKED").contains(values[9])
          || !values[11].matches("[A-Z]{3}") || values[1].isBlank() || values[2].isBlank()
          || values[5].isBlank() || values[6].isBlank()) throw invalid();
      boolean payment = "SUCCESS".equals(values[9]);
      if (payment && (refund != 0 || refundSettlement != 0 || couponRefund != 0 || !"0".equals(values[14])
          || !"0".equals(values[15]) || !values[19].isEmpty())
          || !payment && (order != 0 || settlement != 0 || values[14].isBlank() || "0".equals(values[14])
          || values[15].isBlank() || "0".equals(values[15]) || !List.of("SUCCESS", "PROCESSING", "FAIL", "CHANGE").contains(values[19]))) throw invalid();
      rows.add(new Row(occurredAt, values[1], values[2], values[3], values[5], values[6], values[8], values[9], values[11],
          values[14], values[15], values[18], values[19], order, refund, fee, FamilySubscriptionService.hash(line)));
    }
    if (at + 1 >= lines.length) throw invalid();
    String[] summary = fields(lines[++at], 7);
    if (!summary[0].matches("0|[1-9][0-9]{0,8}") || Long.parseLong(summary[0]) != rows.size()) throw invalid();
    for (int index = 0; index < sums.length; index++) if (money(summary[index + 1], index == 3) != sums[index]) throw invalid();
    for (int index = at + 1; index < lines.length; index++) if (!lines[index].isEmpty()) throw invalid();
    return new Bill(List.copyOf(rows));
  }

  private static String[] fields(String line, int expected) {
    if (line.length() > MAX_LINE) throw invalid();
    String[] fields = line.split(",", -1);
    if (fields.length != expected) throw invalid();
    for (int index = 0; index < fields.length; index++) {
      if (!fields[index].startsWith("`")) throw invalid();
      fields[index] = fields[index].substring(1);
    }
    return fields;
  }

  private static long money(String value, boolean signed) {
    if (!value.matches(signed ? "-?(0|[1-9][0-9]{0,10})\\.[0-9]{2}" : "(0|[1-9][0-9]{0,10})\\.[0-9]{2}")) throw invalid();
    try { return new BigDecimal(value).movePointRight(2).longValueExact(); }
    catch (ArithmeticException malformed) { throw invalid(); }
  }

  record Bill(List<Row> rows) {}
  record Row(long at, String appId, String merchantId, String subMerchantId, String transactionId, String merchantOrderId,
      String tradeType, String state, String currency, String providerRefundId, String merchantRefundId, String refundType,
      String refundState, long orderMinor, long refundMinor, long feeMinor, String evidenceHash) {}
  static final class InvalidBill extends RuntimeException {
    InvalidBill() { super("FAMILY_BILL_FORMAT_OR_SUMMARY_INVALID"); }
  }
  private static InvalidBill invalid() { return new InvalidBill(); }
}
