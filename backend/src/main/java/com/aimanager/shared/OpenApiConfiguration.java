package com.aimanager.shared;

import io.swagger.v3.oas.annotations.OpenAPIDefinition;
import io.swagger.v3.oas.annotations.info.Info;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import io.swagger.v3.oas.annotations.security.SecurityScheme;
import io.swagger.v3.oas.annotations.enums.SecuritySchemeType;
import org.springframework.context.annotation.Configuration;

/** Only implemented controllers are exposed. API_DOCS_ENABLED is opt-in and docs still require authentication. */
@Configuration
@OpenAPIDefinition(info = @Info(title = "AI Manager Management API", version = "v1"),
    security = @SecurityRequirement(name = "bearerAuth"))
@SecurityScheme(name = "bearerAuth", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "JWT")
@SecurityScheme(name = "deviceBearer", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "opaque")
@SecurityScheme(name = "cleanupProof", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "ES256 registered-key proof")
class OpenApiConfiguration {}
