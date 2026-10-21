package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderContracts.*;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Independent platform scopes; family membership and SMS authentication grant no access. */
@RestController
@RequestMapping("/api/v1/platform/identity-providers")
class IdentityProviderController {
  private final ProviderConfigurationService service;private final RecentAuthentication recent;private final ProviderAcceptanceService acceptance;
  IdentityProviderController(ProviderConfigurationService service,RecentAuthentication recent,ProviderAcceptanceService acceptance){this.service=service;this.recent=recent;this.acceptance=acceptance;}
  @GetMapping("/status") ResponseEntity<StatusView> status(Authentication auth,@AuthenticationPrincipal Jwt actor){
    authorize(auth,actor,"read");return response(service.status(scope(auth,"read"),scope(auth,"manage"),scope(auth,"test")));
  }
  @PostMapping("/versions") ResponseEntity<VersionView> save(Authentication auth,@AuthenticationPrincipal Jwt actor,@RequestBody SaveVersion input){
    authorize(auth,actor,"manage");return response(service.save(input,actor.getSubject()));
  }
  @GetMapping("/versions/{id}") ResponseEntity<VersionView> version(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){
    authorize(auth,actor,"read");return response(service.version(id));
  }
  @PostMapping("/versions/{id}/validations") ResponseEntity<ValidationView> validate(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){
    authorize(auth,actor,"test");return response(service.validate(id,actor.getSubject()));
  }
  @PostMapping("/versions/{id}/release-preparations") ResponseEntity<PreparationView> prepare(Authentication auth,@AuthenticationPrincipal Jwt actor,
      @PathVariable String id,@RequestBody PreparationInput input){
    authorize(auth,actor,"manage");if(input==null)throw DomainException.invalid("IDENTITY_PROVIDER_INVALID_INPUT");
    return response(service.prepare(id,input.id(),actor.getSubject()));
  }
  @GetMapping("/release-preparations/{id}") ResponseEntity<PreparationView> preparation(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){
    authorize(auth,actor,"read");return response(service.preparation(id));
  }
  @GetMapping("/versions/{id}/release-preparations") ResponseEntity<PreparationListView> preparations(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){
    authorize(auth,actor,"read");return response(service.preparations(id));
  }
  @PostMapping("/acceptance-runs") ResponseEntity<AcceptanceView> createRun(Authentication auth,@AuthenticationPrincipal Jwt actor,@RequestBody AcceptanceInput input){
    authorize(auth,actor,"test");return response(service.createRun(input,actor.getSubject()));
  }
  @GetMapping("/acceptance-status") ResponseEntity<AcceptanceStatusView> acceptanceStatus(Authentication auth,@AuthenticationPrincipal Jwt actor){
    authorize(auth,actor,"read");return response(acceptance.status());
  }
  @GetMapping("/acceptance-runs") ResponseEntity<AcceptanceListView> runs(Authentication auth,@AuthenticationPrincipal Jwt actor){
    authorize(auth,actor,"read");return response(service.runs());
  }
  @GetMapping("/acceptance-runs/{id}") ResponseEntity<AcceptanceView> run(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){
    authorize(auth,actor,"read");return response(service.run(id));
  }
  private void authorize(Authentication auth,Jwt actor,String required){if(!scope(auth,required))throw DomainException.denied();recent.require(actor);}
  private static boolean scope(Authentication auth,String scope){return auth.getAuthorities().stream().anyMatch(a->a.getAuthority().equals("SCOPE_identity-config:"+scope));}
  private static <T>ResponseEntity<T> response(T value){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization").body(value);}
}
