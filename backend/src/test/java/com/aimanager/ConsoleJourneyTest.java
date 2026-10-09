package com.aimanager;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import org.springframework.http.MediaType;

@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:console;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE", "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc
class ConsoleJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @MockitoBean JwtDecoder decoder;
    @Test void browserPreflightAllowsConfiguredOriginAndVersionedWrites() throws Exception {
        mvc.perform(options("/api/v1/me").header("Origin", "http://localhost:3000")
            .header("Access-Control-Request-Method", "GET")
            .header("Access-Control-Request-Headers", "authorization"))
            .andExpect(status().isOk()).andExpect(header().string("Access-Control-Allow-Origin", "http://localhost:3000"));
        mvc.perform(options("/api/v1/tenants/example/policies/example").header("Origin", "http://localhost:3000")
            .header("Access-Control-Request-Method", "PUT")
            .header("Access-Control-Request-Headers", "authorization,content-type,if-match,idempotency-key"))
            .andExpect(status().isOk());
        mvc.perform(options("/api/v1/me").header("Origin", "https://untrusted.example")
            .header("Access-Control-Request-Method", "GET"))
            .andExpect(status().isForbidden()).andExpect(header().doesNotExist("Access-Control-Allow-Origin"));
    }
    private org.springframework.test.web.servlet.request.RequestPostProcessor actor(String subject) {
        return jwt().jwt(t -> t.subject(subject).claim("email", "admin@example.test"))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private String family(String subject) throws Exception {
        return mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(subject)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"管理空间\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    }
    @Test void profileComesFromValidatedPrincipal() throws Exception {
        mvc.perform(get("/api/v1/me").with(actor("console-owner"))).andExpect(status().isOk())
            .andExpect(jsonPath("$.subject").value("console-owner")).andExpect(jsonPath("$.canCreateTenant").value(true));
        mvc.perform(get("/api/v1/me")).andExpect(status().isUnauthorized());
    }
    @Test void membershipAndMemberListRespectTenantBoundaries() throws Exception {
        String id = family("member-owner");
        mvc.perform(get("/api/v1/tenants/{id}/membership", id).with(actor("member-owner"))).andExpect(status().isOk()).andExpect(jsonPath("$.role").value("OWNER"));
        mvc.perform(get("/api/v1/tenants/{id}/members", id).with(actor("member-owner"))).andExpect(status().isOk()).andExpect(jsonPath("$.items[0].role").value("OWNER"));
        mvc.perform(get("/api/v1/tenants/{id}/members", id).with(actor("stranger"))).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/tenants/{id}/invitations", id).with(actor("stranger"))).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/tenants/{id}/invitations", id).with(actor("member-owner"))).andExpect(status().isOk()).andExpect(jsonPath("$.items").isEmpty());
    }
    @Test void tenantEditRequiresOwnerAndStrongCurrentVersion() throws Exception {
        String id = family("edit-owner");
        String body = "{\"name\":\"新的家庭\",\"timeZone\":\"UTC\"}";
        mvc.perform(patch("/api/v1/tenants/{id}", id).with(actor("stranger")).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
        mvc.perform(patch("/api/v1/tenants/{id}", id).with(actor("edit-owner")).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isPreconditionRequired());
        mvc.perform(patch("/api/v1/tenants/{id}", id).with(actor("edit-owner")).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isOk()).andExpect(header().string("ETag", "\"1\""));
        mvc.perform(patch("/api/v1/tenants/{id}", id).with(actor("edit-owner")).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isPreconditionFailed());
        mvc.perform(get("/api/v1/tenants/{id}/audit-events", id).with(actor("edit-owner"))).andExpect(jsonPath("$.items.length()").value(2));
    }
}
