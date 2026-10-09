package com.aimanager.fleet.internal;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;

/** This exact route is authenticated by one-use enrollment nonce plus key proof, not user JWT. */
@Configuration
class ClaimSecurityConfiguration {
    @Bean @Order(1)
    SecurityFilterChain claimSecurity(HttpSecurity http) throws Exception {
        return http.securityMatcher("/api/v1/enrollment-claims", "/api/v1/enrollment-claims/recover").csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth.anyRequest().permitAll()).build();
    }
}
