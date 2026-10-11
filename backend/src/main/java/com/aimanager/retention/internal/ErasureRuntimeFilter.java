package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.aimanager.shared.SecurityProblems;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.IOException;
import java.util.*;
import org.slf4j.LoggerFactory;
import org.springframework.web.filter.OncePerRequestFilter;

class ErasureRuntimeFilter extends OncePerRequestFilter {
  private final ErasureWorkScope scope;
  private final ObjectMapper json;

  ErasureRuntimeFilter(ErasureWorkScope scope, ObjectMapper json) {
    this.scope = scope;
    this.json = json;
  }

  @Override
  protected boolean shouldNotFilter(HttpServletRequest request) {
    String path = request.getRequestURI().substring(request.getContextPath().length());
    return Set.of("GET", "HEAD").contains(request.getMethod())
        && Set.of("/actuator/health", "/actuator/health/liveness", "/actuator/health/readiness")
            .contains(path);
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    try (var ignored = scope.enter()) {
      chain.doFilter(request, response);
    } catch (ErasureLedger.Failure unavailable) {
      if (response.isCommitted()) {
        LoggerFactory.getLogger(ErasureRuntimeFilter.class)
            .warn(
                "Erasure work admission or release failed after response commit; reconciliation is"
                    + " required");
        return;
      }
      var preserved = new LinkedHashMap<String, List<String>>();
      for (String header :
          List.of(
              "X-Correlation-Id",
              "Access-Control-Allow-Origin",
              "Access-Control-Allow-Credentials",
              "Access-Control-Expose-Headers",
              "Vary")) {
        var values = response.getHeaders(header);
        if (!values.isEmpty()) preserved.put(header, List.copyOf(values));
      }
      response.reset();
      preserved.forEach((name, values) -> values.forEach(value -> response.addHeader(name, value)));
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Retry-After", "30");
      SecurityProblems.write(json, response, 503, "ERASURE_MAINTENANCE_REQUIRED");
    }
  }
}
