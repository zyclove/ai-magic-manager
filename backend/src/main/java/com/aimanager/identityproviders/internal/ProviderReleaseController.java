package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderReleaseContracts.*;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import org.springframework.http.*;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Adult approvals and host execution use separate identities; neither can forge runtime evidence. */
@RestController
@RequestMapping("/api/v1/platform/identity-providers")
class ProviderReleaseController {
  private final ProviderReleaseService service;private final RecentAuthentication recent;
  ProviderReleaseController(ProviderReleaseService service,RecentAuthentication recent){this.service=service;this.recent=recent;}
  @GetMapping("/release-status") ResponseEntity<ReleaseStatusView> status(Authentication auth,@AuthenticationPrincipal Jwt actor){authorize(auth,actor,"read");return response(service.status());}
  @PostMapping("/release-operations") ResponseEntity<ReleaseOperationView> create(Authentication auth,@AuthenticationPrincipal Jwt actor,@RequestBody ReleaseInput input){
    authorize(auth,actor,input!=null&&"ROLLBACK".equals(input.kind())?"rollback":"publish");return response(service.create(input,actor.getSubject()));}
  @GetMapping("/release-operations/{id}") ResponseEntity<ReleaseOperationView> operation(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){authorize(auth,actor,"read");return response(service.operation(id));}
  @PostMapping("/release-operations/{id}/runtime-checks") ResponseEntity<RuntimeCheckView> check(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id,@RequestBody CheckInput input){
    authorize(auth,actor,"test");if(input==null)throw DomainException.invalid("IDENTITY_PROVIDER_INVALID_INPUT");return response(service.check(id,input.id(),actor.getSubject()));}
  @GetMapping("/runtime-checks/{id}") ResponseEntity<RuntimeCheckView> check(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){authorize(auth,actor,"read");return response(service.runtimeCheck(id));}
  @PostMapping("/release-operations/{id}/cancellations") ResponseEntity<ReleaseOperationView> cancel(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id,@RequestBody CancellationInput input){
    authorizeEither(auth,actor);authorize(auth,actor,"ROLLBACK".equals(service.operationKind(id))?"rollback":"publish");return response(service.cancel(id,input,actor.getSubject()));}
  @GetMapping("/cancellations/{id}") ResponseEntity<ReleaseOperationView> cancellation(Authentication auth,@AuthenticationPrincipal Jwt actor,@PathVariable String id){authorize(auth,actor,"read");return response(service.cancellation(id));}
  private void authorizeEither(Authentication auth,Jwt actor){if(!scope(auth,"publish")&&!scope(auth,"rollback"))throw DomainException.denied();recent.require(actor);}
  private void authorize(Authentication auth,Jwt actor,String required){if(!scope(auth,required))throw DomainException.denied();recent.require(actor);}
  private static boolean scope(Authentication auth,String required){return auth.getAuthorities().stream().anyMatch(a->a.getAuthority().equals("SCOPE_identity-config:"+required));}
  static <T>ResponseEntity<T> response(T value){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization").body(value);}
}
