package com.aimanager.deviceidentity;

import com.aimanager.shared.SecurityProblems;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
class DeviceSecurityConfiguration {
    @Bean @Order(2)
    SecurityFilterChain deviceSecurity(HttpSecurity http, DeviceCredentials credentials, ObjectMapper mapper) throws Exception {
        return http.securityMatcher("/api/v1/device-api/**").csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(HttpMethod.POST, "/api/v1/device-api/credentials/activate").hasAuthority("SCOPE_device:credential-activate")
                .anyRequest().hasAuthority("SCOPE_device:operate"))
            .oauth2ResourceServer(oauth -> oauth.opaqueToken(opaque -> opaque.introspector(credentials))
                .authenticationEntryPoint((request, response, failure) -> SecurityProblems.write(mapper, response, 401, "DEVICE_UNAUTHENTICATED")))
            .exceptionHandling(errors -> errors.accessDeniedHandler(
                (request, response, failure) -> SecurityProblems.write(mapper, response, 403, "SCOPE_DENIED")))
            .build();
    }
}
