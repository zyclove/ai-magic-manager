package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialOfferDraft.BillingPeriod;
import com.aimanager.commerce.internal.CommercialOfferDraft.BuyerKind;
import com.aimanager.commerce.internal.CommercialOfferDraft.Channel;
import com.aimanager.commerce.internal.CommercialOfferDraft.DeviceMode;
import com.aimanager.commerce.internal.CommercialOfferDraft.Platform;
import com.aimanager.commerce.internal.CommercialOfferDraft.PriceType;
import com.aimanager.commerce.internal.CommercialOfferDraft.TaxBasis;
import com.aimanager.shared.DomainException;
import java.util.EnumSet;
import java.util.Set;
import org.junit.jupiter.api.Test;

/** Catalog drafts never establish sale eligibility or device authority. */
class CommercialOfferDraftTest {
  private static final long START = 1_790_000_000_000L;
  private static final long END = START + 86_400_000L;

  @Test
  void acceptsExplicitManagedContractDraftAndCopiesFeatures() {
    var features = EnumSet.of(Feature.MANAGED_ANDROID, Feature.ORG_BULK);
    var offer =
        offer(
            "ORG_STANDARD",
            "CN",
            Channel.CONTRACT,
            BuyerKind.ORGANIZATION,
            Platform.ANDROID,
            DeviceMode.FULLY_MANAGED,
            PriceType.FIXED,
            29900L,
            TaxBasis.INCLUSIVE,
            CapacityKind.BASE,
            50,
            features);
    features.clear();
    assertThat(offer.features())
        .containsExactlyInAnyOrder(Feature.MANAGED_ANDROID, Feature.ORG_BULK);
    assertThat(offer.priceMinor()).isEqualTo(29900L);
  }

  @Test
  void familyByodCanBeDraftedWithoutClaimingManagedControl() {
    var offer =
        offer(
            "FAMILY_BASIC",
            "US",
            Channel.GOOGLE_PLAY,
            BuyerKind.FAMILY,
            Platform.ANDROID,
            DeviceMode.BYOD,
            PriceType.FIXED,
            0L,
            TaxBasis.EXCLUSIVE,
            CapacityKind.BASE,
            3,
            Set.of(Feature.ADVANCED_SCHEDULES));
    assertThat(offer.deviceMode()).isEqualTo(DeviceMode.BYOD);
    assertThat(offer.features()).doesNotContain(Feature.MANAGED_ANDROID);
  }

  @Test
  void quoteMustHaveNoAmountOrTaxPromise() {
    var quote =
        offer(
            "PRIVATE_QUOTE",
            "DE",
            Channel.PRIVATE_LICENSE,
            BuyerKind.ORGANIZATION,
            Platform.WINDOWS,
            DeviceMode.BYOD,
            PriceType.QUOTE,
            null,
            TaxBasis.QUOTE_REQUIRED,
            CapacityKind.BASE,
            10,
            Set.of());
    assertThat(quote.priceMinor()).isNull();
    assertThatThrownBy(
            () ->
                offer(
                    "PRIVATE_QUOTE",
                    "DE",
                    Channel.PRIVATE_LICENSE,
                    BuyerKind.ORGANIZATION,
                    Platform.WINDOWS,
                    DeviceMode.BYOD,
                    PriceType.QUOTE,
                    100L,
                    TaxBasis.QUOTE_REQUIRED,
                    CapacityKind.BASE,
                    10,
                    Set.of()))
        .isInstanceOf(DomainException.class)
        .hasMessage("INVALID_COMMERCIAL_PRICE");
  }

  @Test
  void rejectsUncertifiedClaimsInByodAndMismatchedChannels() {
    assertThatThrownBy(
            () ->
                offer(
                    "FAMILY_MANAGED",
                    "CN",
                    Channel.CONTRACT,
                    BuyerKind.FAMILY,
                    Platform.ANDROID_TV,
                    DeviceMode.BYOD,
                    PriceType.FIXED,
                    1L,
                    TaxBasis.INCLUSIVE,
                    CapacityKind.BASE,
                    1,
                    Set.of(Feature.MANAGED_ANDROID)))
        .hasMessage("INVALID_COMMERCIAL_APPLICABILITY");
    assertThatThrownBy(
            () ->
                offer(
                    "APP_STORE_ANDROID",
                    "US",
                    Channel.APP_STORE,
                    BuyerKind.FAMILY,
                    Platform.ANDROID,
                    DeviceMode.BYOD,
                    PriceType.FIXED,
                    1L,
                    TaxBasis.EXCLUSIVE,
                    CapacityKind.BASE,
                    1,
                    Set.of()))
        .hasMessage("INVALID_COMMERCIAL_APPLICABILITY");
  }

  @Test
  void rejectsInvalidRegionSkuCapacityAndWindow() {
    assertThatThrownBy(
            () ->
                offer(
                    "lowercase",
                    "CN",
                    Channel.CONTRACT,
                    BuyerKind.FAMILY,
                    Platform.ANDROID,
                    DeviceMode.BYOD,
                    PriceType.FIXED,
                    1L,
                    TaxBasis.INCLUSIVE,
                    CapacityKind.BASE,
                    1,
                    Set.of()))
        .hasMessage("INVALID_COMMERCIAL_OFFER");
    assertThatThrownBy(
            () ->
                offer(
                    "FAMILY_BASIC",
                    "ZZ",
                    Channel.CONTRACT,
                    BuyerKind.FAMILY,
                    Platform.ANDROID,
                    DeviceMode.BYOD,
                    PriceType.FIXED,
                    1L,
                    TaxBasis.INCLUSIVE,
                    CapacityKind.BASE,
                    1,
                    Set.of()))
        .hasMessage("INVALID_COMMERCIAL_OFFER");
    assertThatThrownBy(
            () ->
                offer(
                    "FAMILY_BASIC",
                    "CN",
                    Channel.CONTRACT,
                    BuyerKind.FAMILY,
                    Platform.ANDROID,
                    DeviceMode.BYOD,
                    PriceType.FIXED,
                    1L,
                    TaxBasis.INCLUSIVE,
                    CapacityKind.BASE,
                    0,
                    Set.of()))
        .hasMessage("INVALID_COMMERCIAL_CAPACITY");
    assertThatThrownBy(
            () ->
                new CommercialOfferDraft(
                    "FAMILY_BASIC",
                    1,
                    "CN",
                    Channel.CONTRACT,
                    BuyerKind.FAMILY,
                    Platform.ANDROID,
                    DeviceMode.BYOD,
                    BillingPeriod.YEAR,
                    PriceType.FIXED,
                    "CNY",
                    1L,
                    TaxBasis.INCLUSIVE,
                    CapacityKind.BASE,
                    1,
                    Set.of(),
                    END,
                    START))
        .hasMessage("INVALID_COMMERCIAL_OFFER");
  }

  private CommercialOfferDraft offer(
      String sku,
      String region,
      Channel channel,
      BuyerKind buyer,
      Platform platform,
      DeviceMode mode,
      PriceType priceType,
      Long amount,
      TaxBasis taxBasis,
      CapacityKind capacityKind,
      int capacity,
      Set<Feature> features) {
    return new CommercialOfferDraft(
        sku,
        1,
        region,
        channel,
        buyer,
        platform,
        mode,
        BillingPeriod.YEAR,
        priceType,
        "CNY",
        amount,
        taxBasis,
        capacityKind,
        capacity,
        features,
        START,
        END);
  }
}
