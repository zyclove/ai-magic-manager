package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderReleaseContracts.*;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/** Fixed typed host requests authenticated with the independent executor HMAC key in the service. */
@RestController
@RequestMapping("/api/v1/platform/identity-provider-executor")
class ProviderExecutorController {
  private final ProviderReleaseService service;
  ProviderExecutorController(ProviderReleaseService service){this.service=service;}
  @PostMapping("/claims") ResponseEntity<ExecutorView> claim(@RequestBody ExecutorInput input){return ProviderReleaseController.response(service.machine("CLAIM",input));}
  @PostMapping("/claims/query") ResponseEntity<ExecutorView> query(@RequestBody ExecutorInput input){return ProviderReleaseController.response(service.machine("QUERY",input));}
  @PostMapping("/claims/begin") ResponseEntity<ExecutorView> begin(@RequestBody ExecutorInput input){return ProviderReleaseController.response(service.machine("BEGIN",input));}
  @PostMapping("/claims/outcomes") ResponseEntity<ExecutorView> report(@RequestBody ExecutorInput input){return ProviderReleaseController.response(service.machine("REPORT",input));}
  @PostMapping("/claims/abandon") ResponseEntity<ExecutorView> abandon(@RequestBody ExecutorInput input){return ProviderReleaseController.response(service.machine("ABANDON_BEFORE_BEGIN",input));}
}
