package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class FamilyWechatBillGatewayTest {
  FamilyWechatV3Gateway payment;
  FamilyWechatBillGateway bill;
  ObjectMapper json = new ObjectMapper();
  byte[] bytes = FamilyTradeBillParserTest.bytes(FamilyTradeBillParserTest.payment("a".repeat(32), "tx-1"));
  String path = "/v3/bill/tradebill?bill_date=2026-10-15&bill_type=ALL";
  String url = "https://api.mch.weixin.qq.com/v3/billdownload/file?token=opaque-download-token";

  @BeforeEach void setup() {
    payment = mock(FamilyWechatV3Gateway.class);
    when(payment.verificationAvailable()).thenReturn(true);
    when(payment.available()).thenReturn(false);
    when(payment.billAppId()).thenReturn("wx-app");
    when(payment.billMerchantId()).thenReturn("1900000001");
    bill = new FamilyWechatBillGateway(payment);
  }

  @Test void maintenanceCanDownloadWhenNewSalesAreClosedUsingTheSignedMetadataAndExactFileHash() throws Exception {
    when(payment.signedBillRead(path)).thenReturn(json.readTree("{\"hash_type\":\"SHA1\",\"hash_value\":\"" + FamilyBillGateway.sha1(bytes) + "\",\"download_url\":\"" + url + "\"}"));
    when(payment.downloadBill(URI.create(url), FamilyTradeBillParser.MAX_BYTES)).thenReturn(bytes);
    assertThat(bill.available()).isTrue();
    var result = bill.download(FamilyTradeBillParserTest.DAY);
    assertThat(result.bytes()).isEqualTo(bytes);
    verify(payment).signedBillRead(path);
    verify(payment).downloadBill(URI.create(url), FamilyTradeBillParser.MAX_BYTES);
    result.bytes()[0] = 0;
    assertThat(result.bytes()).isEqualTo(bytes);
  }

  @Test void downloadMetadataMustBeCompleteAndRestrictedToExactOfficialOriginAndPaths() throws Exception {
    for (String badUrl : new String[] {"http://api.mch.weixin.qq.com/v3/billdownload/file?token=x", "https://evil.example/v3/billdownload/file?token=x",
        "https://api.mch.weixin.qq.com.evil.example/v3/billdownload/file?token=x", "https://api.mch.weixin.qq.com/v3/pay/transactions/app?token=x",
        "https://api.mch.weixin.qq.com/v3/billdownload/file?token=x&callback=y", "https://api.mch.weixin.qq.com/v3/billdownload/file?token=x#fragment"}) {
      when(payment.signedBillRead(path)).thenReturn(json.readTree("{\"hash_type\":\"SHA1\",\"hash_value\":\"" + FamilyBillGateway.sha1(bytes) + "\",\"download_url\":\"" + badUrl + "\"}"));
      assertThatThrownBy(() -> bill.download(FamilyTradeBillParserTest.DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
    }
    verify(payment, never()).downloadBill(any(), anyInt());
  }

  @Test void unknownHashAlgorithmAndTruncatedFileAreNotReturnedAsTrustedBill() throws Exception {
    when(payment.signedBillRead(path)).thenReturn(json.readTree("{\"hash_type\":\"MD5\",\"hash_value\":\"" + FamilyBillGateway.sha1(bytes) + "\",\"download_url\":\"" + url + "\"}"));
    assertThatThrownBy(() -> bill.download(FamilyTradeBillParserTest.DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
    when(payment.signedBillRead(path)).thenReturn(json.readTree("{\"hash_type\":\"SHA1\",\"hash_value\":\"" + "0".repeat(40) + "\",\"download_url\":\"" + url + "\"}"));
    when(payment.downloadBill(URI.create(url), FamilyTradeBillParser.MAX_BYTES)).thenReturn(bytes);
    assertThatThrownBy(() -> bill.download(FamilyTradeBillParserTest.DAY)).isInstanceOf(FamilyTradeBillParser.InvalidBill.class);
  }
}
