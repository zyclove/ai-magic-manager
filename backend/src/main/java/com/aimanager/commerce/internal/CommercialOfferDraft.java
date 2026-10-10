package com.aimanager.commerce.internal;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.shared.DomainException;
import java.time.Duration;
import java.util.Currency;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Operator-authored catalog draft, not a purchase or entitlement. Publication must separately
 * verify regional, channel, price, compatibility and support evidence.
 */
record CommercialOfferDraft(
    String sku,
    int skuVersion,
    String region,
    Channel channel,
    BuyerKind buyerKind,
    Platform platform,
    DeviceMode deviceMode,
    BillingPeriod billingPeriod,
    PriceType priceType,
    String currency,
    Long priceMinor,
    TaxBasis taxBasis,
    CapacityKind capacityKind,
    int deviceCapacity,
    Set<Feature> features,
    long availableFrom,
    long availableUntil) {
  private static final Pattern SKU = Pattern.compile("[A-Z0-9_]{1,80}");
  private static final Pattern ISO_CODE = Pattern.compile("[A-Z]{2}");
  private static final Pattern CURRENCY_CODE = Pattern.compile("[A-Z]{3}");
  private static final Set<String> REGIONS = Set.of(Locale.getISOCountries());
  private static final long MAX_PRICE_MINOR = 1_000_000_000_000L;
  private static final long MAX_WINDOW_MILLIS = Duration.ofDays(3650).toMillis();

  CommercialOfferDraft {
    if (sku == null
        || !SKU.matcher(sku).matches()
        || skuVersion < 1
        || region == null
        || !ISO_CODE.matcher(region).matches()
        || !REGIONS.contains(region)
        || channel == null
        || buyerKind == null
        || platform == null
        || deviceMode == null
        || billingPeriod == null
        || priceType == null
        || !validCurrency(currency)
        || taxBasis == null
        || capacityKind == null
        || deviceCapacity < 0
        || deviceCapacity > 1_000_000
        || features == null
        || features.stream().anyMatch(Objects::isNull)
        || availableFrom < 0
        || availableUntil <= availableFrom
        || availableUntil - availableFrom > MAX_WINDOW_MILLIS) {
      throw DomainException.invalid("INVALID_COMMERCIAL_OFFER");
    }
    features = Set.copyOf(features);
    if (priceType == PriceType.FIXED
        ? priceMinor == null || priceMinor < 0 || priceMinor > MAX_PRICE_MINOR
        : priceMinor != null || taxBasis != TaxBasis.QUOTE_REQUIRED) {
      throw DomainException.invalid("INVALID_COMMERCIAL_PRICE");
    }
    if (priceType == PriceType.FIXED && taxBasis == TaxBasis.QUOTE_REQUIRED) {
      throw DomainException.invalid("INVALID_COMMERCIAL_PRICE");
    }
    if (capacityKind == CapacityKind.BASE && deviceCapacity == 0) {
      throw DomainException.invalid("INVALID_COMMERCIAL_CAPACITY");
    }
    if ((channel == Channel.APP_STORE && platform != Platform.IOS)
        || (channel == Channel.GOOGLE_PLAY
            && platform != Platform.ANDROID
            && platform != Platform.ANDROID_TV)
        || (deviceMode == DeviceMode.WORK_PROFILE && platform != Platform.ANDROID)
        || (features.contains(Feature.MANAGED_ANDROID)
            && (deviceMode == DeviceMode.BYOD
                || (platform != Platform.ANDROID && platform != Platform.ANDROID_TV)))
        || (features.contains(Feature.ORG_BULK) && buyerKind != BuyerKind.ORGANIZATION)) {
      throw DomainException.invalid("INVALID_COMMERCIAL_APPLICABILITY");
    }
  }

  private static boolean validCurrency(String code) {
    if (code == null || !CURRENCY_CODE.matcher(code).matches() || "XXX".equals(code)) return false;
    try {
      return Currency.getInstance(code) != null;
    } catch (IllegalArgumentException error) {
      return false;
    }
  }

  enum Channel {
    GOOGLE_PLAY,
    APP_STORE,
    CONTRACT,
    PRIVATE_LICENSE
  }

  enum BuyerKind {
    FAMILY,
    ORGANIZATION
  }

  enum Platform {
    ANDROID,
    ANDROID_TV,
    IOS,
    WINDOWS,
    MACOS
  }

  enum DeviceMode {
    BYOD,
    WORK_PROFILE,
    FULLY_MANAGED,
    DEDICATED
  }

  enum BillingPeriod {
    MONTH,
    YEAR,
    ONE_TIME
  }

  enum PriceType {
    FIXED,
    QUOTE
  }

  enum TaxBasis {
    INCLUSIVE,
    EXCLUSIVE,
    QUOTE_REQUIRED
  }
}
