package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import org.junit.jupiter.api.Test;

class FamilyTradeBillParserTest {
  static final String HEADER = "交易时间,公众账号ID,商户号,特约商户号,设备号,微信订单号,商户订单号,用户标识,交易类型,交易状态,付款银行,货币种类,应结订单金额,代金券金额,微信退款单号,商户退款单号,退款金额,充值券退款金额,退款类型,退款状态,商品名称,商户数据包,手续费,费率,订单金额,申请退款金额,费率备注";
  static final String FOOTER = "总交易单数,应结订单总金额,退款总金额,充值券退款总金额,手续费总金额,订单总金额,申请退款总金额";
  static final LocalDate DAY = LocalDate.of(2026, 10, 15);

  @Test void parsesExactMinorAmountsAndKeepsOnlyOpaqueReferences() {
    var bill = FamilyTradeBillParser.parse(bytes(payment("a".repeat(32), "tx-1")), DAY);
    assertThat(bill.rows()).hasSize(1);
    var row = bill.rows().get(0);
    assertThat(row.orderMinor()).isEqualTo(1900);
    assertThat(row.feeMinor()).isEqualTo(11);
    assertThat(row.transactionId()).isEqualTo("tx-1");
    assertThat(row.at()).isEqualTo(DAY.atTime(23, 59, 59).atZone(java.time.ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli());
    assertThat(row.toString()).doesNotContain("payer-private", "孩子游戏");
  }

  @Test void summaryMustMatchEveryRowAndEveryMoneyColumn() {
    assertThatThrownBy(() -> FamilyTradeBillParser.parse(bytes(payment("a".repeat(32), "tx-1").replace("`19.00,`0.00\n", "`18.99,`0.00\n")), DAY))
        .isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
  }

  @Test void rejectsTruncatedUnknownLayoutNonFiniteMoneyAndTrailingRecords() {
    String valid = payment("a".repeat(32), "tx-1");
    for (String invalid : new String[] {valid.substring(0, valid.lastIndexOf("\n`1,")), valid.replace("订单金额,申请退款金额", "总金额,申请退款金额"),
        valid.replace("`19.00", "`1.9e1"), valid + "`another-record\n", valid.replace("`19.00", "`19.001")}) {
      assertThatThrownBy(() -> FamilyTradeBillParser.parse(bytes(invalid), DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
    }
  }

  @Test void refundUsesRequestAmountAndAcceptedTimeRatherThanSettlementAmount() {
    String refund = "`2026-10-15 08:10:00,`wx-app,`1900000001,`0,`, `tx-1,`" + "a".repeat(32)
        + ",`payer-private,`APP,`REFUND,`OTHERS,`CNY,`0.00,`0.00,`rf-1,`" + "b".repeat(32)
        + ",`17.00,`0.00,`ORIGINAL,`PROCESSING,`孩子游戏,`, `-0.10,`0.60%,`0.00,`19.00,`";
    String csv = HEADER + "\n" + refund.replace(", `", ",`") + "\n" + FOOTER + "\n`1,`0.00,`17.00,`0.00,`-0.10,`0.00,`19.00\n";
    var row = FamilyTradeBillParser.parse(bytes(csv), DAY).rows().get(0);
    assertThat(row.refundMinor()).isEqualTo(1900);
    assertThat(row.state()).isEqualTo("REFUND");
    assertThat(row.refundState()).isEqualTo("PROCESSING");
  }

  @Test void onlyACompleteZeroRowBillCanBeParsedAsEmpty() {
    assertThat(FamilyTradeBillParser.parse(bytes(HEADER + "\n" + FOOTER + "\n`0,`0.00,`0.00,`0.00,`0.00,`0.00,`0.00\n"), DAY).rows()).isEmpty();
    assertThatThrownBy(() -> FamilyTradeBillParser.parse(new byte[0], DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
    assertThatThrownBy(() -> FamilyTradeBillParser.parse(new byte[] {(byte) 0xc3, 0x28}, DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
  }

  static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }
  static String payment(String order, String transaction) {
    return (HEADER + "\n`2026-10-15 23:59:59,`wx-app,`1900000001,`0,`, `" + transaction + ",`" + order
        + ",`payer-private,`APP,`SUCCESS,`OTHERS,`CNY,`19.00,`0.00,`0,`0,`0.00,`0.00,`,`, `孩子游戏,`, `0.11,`0.60%,`19.00,`0.00,`\n"
        + FOOTER + "\n`1,`19.00,`0.00,`0.00,`0.11,`19.00,`0.00\n").replace(", `", ",`");
  }
}
