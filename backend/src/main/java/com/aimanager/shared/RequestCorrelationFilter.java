package com.aimanager.shared;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/** Server-generated IDs prevent untrusted header text from entering logs. Bodies are never logged. */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
class RequestCorrelationFilter extends OncePerRequestFilter {
    private static final Logger LOG = LoggerFactory.getLogger(RequestCorrelationFilter.class);

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String id = UUID.randomUUID().toString();
        MDC.put("correlationId", id);
        response.setHeader("X-Correlation-Id", id);
        long start = System.nanoTime();
        try {
            chain.doFilter(request, response);
        } finally {
            LOG.info("request method={} status={} durationMs={} correlationId={}",
                request.getMethod(), response.getStatus(), (System.nanoTime() - start) / 1_000_000, id);
            MDC.remove("correlationId");
        }
    }
}
