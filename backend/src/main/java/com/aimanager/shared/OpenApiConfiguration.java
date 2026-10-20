package com.aimanager.shared;

import io.swagger.v3.oas.annotations.OpenAPIDefinition;
import io.swagger.v3.oas.annotations.info.Info;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import io.swagger.v3.oas.annotations.security.SecurityScheme;
import io.swagger.v3.oas.annotations.enums.SecuritySchemeType;
import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.PathItem.HttpMethod;
import io.swagger.v3.oas.models.media.Content;
import io.swagger.v3.oas.models.media.IntegerSchema;
import io.swagger.v3.oas.models.media.MediaType;
import io.swagger.v3.oas.models.media.ObjectSchema;
import io.swagger.v3.oas.models.media.Schema;
import io.swagger.v3.oas.models.media.StringSchema;
import io.swagger.v3.oas.models.responses.ApiResponse;
import io.swagger.v3.oas.models.responses.ApiResponses;
import java.util.List;
import java.util.Map;
import org.springdoc.core.customizers.OpenApiCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Only implemented controllers are exposed. API_DOCS_ENABLED is opt-in and docs still require authentication. */
@Configuration
@OpenAPIDefinition(info = @Info(title = "AI Manager Management API", version = "v1"),
    security = @SecurityRequirement(name = "bearerAuth"))
@SecurityScheme(name = "bearerAuth", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "JWT")
@SecurityScheme(name = "deviceBearer", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "opaque")
@SecurityScheme(name = "cleanupProof", type = SecuritySchemeType.HTTP, scheme = "bearer", bearerFormat = "ES256 registered-key proof")
class OpenApiConfiguration {
  private static final String RESULT_PROBLEM = "OperationResultUnavailableProblem";

  // These are implemented recovery endpoints. Do not advertise result-retention
  // semantics for independent device jobs, current-resource reads or planned APIs.
  private static final Map<String, HttpMethod> RESULT_RECOVERY_ROUTES = Map.ofEntries(
      Map.entry("/api/v1/device-api/access-submissions/recovery", HttpMethod.POST),
      Map.entry("/api/v1/device-api/access-submissions/{requestId}/cancel-recovery", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/applications/creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/applications/{applicationId}/classification/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/device-groups/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/devices/{deviceId}/permission-observation-settings/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/policy-draft-creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/policies/{policyId}/publication-results/{requestId}", HttpMethod.GET),
      Map.entry("/api/v1/tenants/{tenantId}/quota-pools/creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/quota-pools/{poolId}/adjustment-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/quota-plans/creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/quota-plans/{planId}/update-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenant}/audit-exports/creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/schedules/creation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/subjects/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/invitations/{invitationId}/acceptance-results/{requestId}", HttpMethod.GET),
      Map.entry("/api/v1/tenants/{tenantId}/invitations/issuance-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/members/{memberKey}/access-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/classes/operation-results/{requestId}/query", HttpMethod.POST),
      Map.entry("/api/v1/tenants/{tenantId}/ownership-transfers/operation-results/{requestId}/query", HttpMethod.POST));

  @Bean
  OpenApiCustomizer operationResultRetentionResponses() {
    return api -> {
      if (api.getPaths() == null) return;
      if (api.getComponents() == null) api.setComponents(new Components());

      var problem = new ObjectSchema();
      problem.setDescription("A historical operation result can no longer be recovered. "
          + "This does not mean the operation was never committed and never authorizes a retry.");
      problem.addProperty("status", new IntegerSchema()._enum(List.of(410)));
      problem.addProperty("errorCode", new StringSchema()._enum(List.of(
          "IDEMPOTENCY_RESULT_EXPIRED", "IDEMPOTENCY_RESPONSE_ERASED")));
      problem.addProperty("messageKey", new StringSchema());
      problem.addProperty("correlationId", new StringSchema());
      problem.setRequired(List.of("status", "errorCode"));
      api.getComponents().addSchemas(RESULT_PROBLEM, problem);

      RESULT_RECOVERY_ROUTES.forEach((path, method) -> {
        var item = api.getPaths().get(path);
        if (item == null) return;
        var operation = item.readOperationsMap().get(method);
        if (operation == null) return;
        if (operation.getResponses() == null) operation.setResponses(new ApiResponses());
        operation.getResponses().putIfAbsent("410", new ApiResponse()
            .description("IDEMPOTENCY_RESULT_EXPIRED: the original successful result reached its "
                + "fixed 90-day recovery deadline. IDEMPOTENCY_RESPONSE_ERASED: subject erasure "
                + "permanently removed the original response and takes precedence over expiry. "
                + "Recheck current records under current authority; do not resend the old request "
                + "or generate a replacement key automatically. The original key remains fenced.")
            .content(new Content().addMediaType("application/problem+json", new MediaType()
                .schema(new Schema<>().$ref("#/components/schemas/" + RESULT_PROBLEM)))));
      });
    };
  }
}
