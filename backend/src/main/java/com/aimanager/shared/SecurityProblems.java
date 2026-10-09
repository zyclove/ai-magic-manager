package com.aimanager.shared;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Locale;
import java.util.Map;
import org.slf4j.MDC;
import org.springframework.http.MediaType;

/** Identical safe JSON shape for authentication errors on user and device routes. */
public final class SecurityProblems {
    private SecurityProblems() {}
    public static void write(ObjectMapper mapper, HttpServletResponse response, int status, String code) throws IOException {
        response.setStatus(status);
        response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        mapper.writeValue(response.getOutputStream(), Map.of("type", "about:blank", "status", status, "errorCode", code,
            "messageKey", "error." + code.toLowerCase(Locale.ROOT), "correlationId", String.valueOf(MDC.get("correlationId"))));
    }
}
