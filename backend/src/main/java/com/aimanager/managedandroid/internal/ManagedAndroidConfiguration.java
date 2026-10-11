package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.SafetyCriticalPackages;
import com.google.api.client.googleapis.javanet.GoogleNetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.google.auth.http.HttpCredentialsAdapter;
import com.google.auth.oauth2.GoogleCredentials;
import java.io.IOException;
import java.security.GeneralSecurityException;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Safe provider selection. Live Google credentials are loaded only after both activation gates
 * pass.
 */
@Configuration(proxyBeanMethods = false)
class ManagedAndroidConfiguration {
  private static final String SCOPE = "https://www.googleapis.com/auth/androidmanagement";

  @Bean
  @ConditionalOnMissingBean(ManagedAndroidGateway.class)
  ManagedAndroidGateway managedAndroidGateway(
      @Value("${manager.emm.google.enabled:false}") boolean enabled,
      @Value("${manager.emm.google.eligibility-confirmed:false}") boolean eligibilityConfirmed,
      @Value("${manager.emm.target-country-code:CN}") String targetCountryCode,
      @Value("${manager.policies.additional-protected-packages:}") String protectedPackages)
      throws IOException, GeneralSecurityException {
    if (!enabled) return new UnavailableManagedAndroidGateway();
    if (!targetCountryCode.matches("[A-Z]{2}"))
      throw new IllegalStateException("Invalid managed Android target country code");
    if ("CN".equalsIgnoreCase(targetCountryCode)) {
      throw new IllegalStateException(
          "Google Android Enterprise provider is unavailable for the configured mainland China target market");
    }
    if (!eligibilityConfirmed) {
      throw new IllegalStateException(
          "Android Enterprise EMM eligibility must be confirmed before enabling Google provider");
    }
    GoogleCredentials credentials =
        GoogleCredentials.getApplicationDefault().createScoped(List.of(SCOPE));
    AndroidManagement client =
        new AndroidManagement.Builder(
                GoogleNetHttpTransport.newTrustedTransport(),
                GsonFactory.getDefaultInstance(),
                new HttpCredentialsAdapter(credentials))
            .setApplicationName("ai-manager-managed-android")
            .build();
    return new GoogleManagedAndroidGateway(
        client, SafetyCriticalPackages.withAdditional(protectedPackages));
  }

  /** Prevents a partner bean from silently shadowing an enabled Google configuration. */
  @Bean
  SmartInitializingSingleton managedProviderSelection(
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.google.enabled:false}") boolean googleEnabled,
      @Value("${manager.emm.google.eligibility-confirmed:false}") boolean eligibilityConfirmed,
      @Value("${manager.emm.target-country-code:CN}") String targetCountryCode) {
    return () -> {
      if (!targetCountryCode.matches("[A-Z]{2}"))
        throw new IllegalStateException("Invalid managed Android target country code");
      if (gateway.providerCode() == null
          || !gateway.providerCode().matches("[A-Z][A-Z0-9_]{2,31}"))
        throw new IllegalStateException("Invalid managed Android provider code");
      if (googleEnabled && !"GOOGLE_AMAPI".equals(gateway.providerCode()))
        throw new IllegalStateException("Google EMM enabled but a different provider was selected");
      if (gateway.available() && "GOOGLE_AMAPI".equals(gateway.providerCode())
          && (!googleEnabled || !eligibilityConfirmed))
        throw new IllegalStateException("Google EMM provider requires explicit eligibility gates");
      if (gateway.available() && "GOOGLE_AMAPI".equals(gateway.providerCode())
          && "CN".equalsIgnoreCase(targetCountryCode))
        throw new IllegalStateException(
            "Google Android Enterprise provider is unavailable for the configured mainland China target market");
    };
  }
}
