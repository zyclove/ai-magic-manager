package com.aimanager.lifecycle.internal;

import com.aimanager.shared.SecurityProblems;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.context.annotation.*;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

/** No cleanup proof is accepted by the regular user/device chains, and unknown cleanup paths are denied. */
@Configuration
class CleanupSecurityConfiguration {
    @Bean @Order(0)
    SecurityFilterChain cleanupSecurity(HttpSecurity http, CleanupAuthentication authentication, ObjectMapper mapper) throws Exception {
        return http.securityMatcher("/api/v1/device-cleanup/**").csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth.requestMatchers(HttpMethod.GET, "/api/v1/device-cleanup/command", "/api/v1/device-cleanup/signing-keys").hasAuthority("SCOPE_device:cleanup-read")
                .requestMatchers(HttpMethod.POST, "/api/v1/device-cleanup/receipts").hasAuthority("SCOPE_device:cleanup-receipt").anyRequest().denyAll())
            .oauth2ResourceServer(oauth -> oauth.opaqueToken(opaque -> opaque.introspector(authentication))
                .authenticationEntryPoint((request, response, failure) -> SecurityProblems.write(mapper, response, 401, "CLEANUP_UNAUTHENTICATED")))
            .exceptionHandling(errors -> errors.accessDeniedHandler(
                (request, response, failure) -> SecurityProblems.write(mapper, response, 403, "SCOPE_DENIED"))).build();
    }
}
