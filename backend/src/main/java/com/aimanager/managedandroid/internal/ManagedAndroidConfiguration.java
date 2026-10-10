package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.google.api.client.googleapis.javanet.GoogleNetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.google.auth.http.HttpCredentialsAdapter;
import com.google.auth.oauth2.GoogleCredentials;
import java.io.IOException;
import java.security.GeneralSecurityException;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
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
  ManagedAndroidGateway managedAndroidGateway(
      @Value("${manager.emm.google.enabled:false}") boolean enabled,
      @Value("${manager.emm.google.eligibility-confirmed:false}") boolean eligibilityConfirmed)
      throws IOException, GeneralSecurityException {
    if (!enabled) return new UnavailableManagedAndroidGateway();
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
    return new GoogleManagedAndroidGateway(client);
  }
}
