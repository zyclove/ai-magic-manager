package com.aimanager.identity;

import com.aimanager.shared.SecurityProblems;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Collection;
import java.util.Objects;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.filter.OncePerRequestFilter;

/** 仅在 Spring 完成签名和发行者校验后校验消费账号当前会话，业务控制器不接受过期手机号凭据。 */
final class ConsumerSessionGate extends OncePerRequestFilter {
    private final boolean enabled;
    private final ConsumerSessionStatusClient client;
    private final ObjectMapper mapper;

    ConsumerSessionGate(boolean enabled, ConsumerSessionStatusClient client, ObjectMapper mapper) {
        this.enabled = enabled;
        this.client = enabled ? Objects.requireNonNull(client) : client;
        this.mapper = Objects.requireNonNull(mapper);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        if (!enabled || !(authentication instanceof JwtAuthenticationToken bearer) || !bearer.isAuthenticated()
                || !consumerSession(bearer.getToken())) {
            chain.doFilter(request, response);
            return;
        }
        var result = client.check(bearer.getToken());
        if (result == ConsumerSessionStatusClient.Result.CURRENT) {
            chain.doFilter(request, response);
            return;
        }
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("Pragma", "no-cache");
        SecurityProblems.write(mapper, response,
            result == ConsumerSessionStatusClient.Result.STALE ? 401 : 503,
            result == ConsumerSessionStatusClient.Result.STALE ? "ACCOUNT_SESSION_STALE" : "ACCOUNT_SECURITY_UNAVAILABLE");
    }

    private static boolean consumerSession(Jwt jwt) {
        if (!"ai-manager-parent".equals(jwt.getClaims().get("azp"))) {
            return false;
        }
        var claims = jwt.getClaims();
        Object methods = claims.get("amr");
        return claims.containsKey("consumer_identity_revision") || claims.containsKey("phone_number")
            || claims.containsKey("phone_number_verified")
            || methods instanceof Collection<?> collection && (collection.contains("sms") || collection.contains("wechat"))
            || "sms".equals(methods) || "wechat".equals(methods);
    }
}
