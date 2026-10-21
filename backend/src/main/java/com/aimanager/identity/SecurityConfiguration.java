package com.aimanager.identity;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.aimanager.shared.SecurityProblems;
import jakarta.servlet.http.HttpServletResponse;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.core.*;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.security.oauth2.server.resource.web.authentication.BearerTokenAuthenticationFilter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

/** OIDC protocol is delegated to Spring/Nimbus. Tenant roles are evaluated from persisted membership. */
@Configuration
class SecurityConfiguration {
    @Bean
    @ConditionalOnMissingBean(JwtDecoder.class)
    JwtDecoder jwtDecoder(@Value("${manager.security.issuer-uri}") String issuer,
                          @Value("${manager.security.audience}") String audience,
                          @Value("${manager.security.jwk-set-uri:}") String jwkSetUri) {
        // A trusted internal key endpoint can differ from the browser-visible
        // issuer. Signature verification never replaces issuer/audience checks.
        var decoder = jwkSetUri.isBlank()
            ? NimbusJwtDecoder.withIssuerLocation(issuer).build()
            : NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build();
        decoder.setJwtValidator(IdentityTokenValidators.forIssuerAndAudience(issuer, audience));
        return decoder;
    }

    @Bean @Order(3)
    SecurityFilterChain securityFilterChain(HttpSecurity http, ObjectMapper mapper,
            @org.springframework.beans.factory.annotation.Qualifier("corsConfigurationSource") CorsConfigurationSource corsSource,
            @Value("${manager.consumer-security.enabled:false}") boolean consumerSecurityEnabled,
            @Value("${manager.consumer-security.status-url:}") String consumerStatusUrl,
            @Value("${manager.consumer-security.timeout-millis:2000}") int consumerTimeoutMillis) throws Exception {
        // 只加入安全链，不声明 servlet Filter Bean，避免签名校验前重复执行。
        var consumerGate = new ConsumerSessionGate(consumerSecurityEnabled, consumerSecurityEnabled
            ? new ConsumerSessionStatusClient(consumerStatusUrl, consumerTimeoutMillis, mapper) : null, mapper);
        return http.cors(cors -> cors.configurationSource(corsSource)).csrf(csrf -> csrf.disable())
            .addFilterAfter(consumerGate, BearerTokenAuthenticationFilter.class)
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health", "/actuator/health/**").permitAll()
                .requestMatchers(HttpMethod.POST, "/api/v1/payments/wechat/notifications").permitAll()
                // Independent host HMAC authentication is mandatory inside these typed handlers.
                .requestMatchers(HttpMethod.POST, "/api/v1/platform/identity-provider-executor/claims",
                    "/api/v1/platform/identity-provider-executor/claims/query",
                    "/api/v1/platform/identity-provider-executor/claims/begin",
                    "/api/v1/platform/identity-provider-executor/claims/outcomes",
                    "/api/v1/platform/identity-provider-executor/claims/abandon").permitAll()
                .requestMatchers(HttpMethod.POST, "/api/v1/tenants").hasAuthority("SCOPE_tenant:create")
                .anyRequest().authenticated())
            .oauth2ResourceServer(oauth -> oauth.jwt(jwt -> {}).authenticationEntryPoint(
                (request, response, failure) -> write(mapper, response, 401, "UNAUTHENTICATED")))
            .exceptionHandling(errors -> errors.accessDeniedHandler(
                (request, response, failure) -> write(mapper, response, 403, "SCOPE_DENIED")))
            .build();
    }

    private void write(ObjectMapper mapper, HttpServletResponse response, int status, String code) throws java.io.IOException {
        SecurityProblems.write(mapper, response, status, code);
    }

    @Bean
    CorsConfigurationSource corsConfigurationSource(@Value("${manager.security.allowed-origins}") String origins) {
        var config = new CorsConfiguration();
        config.setAllowedOrigins(Arrays.stream(origins.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList());
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("Authorization", "Content-Type", "Idempotency-Key", "If-Match"));
        config.setExposedHeaders(List.of("X-Correlation-Id", "ETag"));
        config.setAllowCredentials(false); // Bearer-only API: no cookie session, therefore no ambient cookie authentication.
        var source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/api/**", config);
        return source;
    }
}
