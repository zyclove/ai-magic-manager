package com.aimanager.policy.internal;

import com.aimanager.shared.AndroidRuntimePermissions;
import java.util.List;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Source of valid Android runtime permission rule names for authenticated policy editors. */
@RestController
class RuntimePermissionCatalogController {
  @GetMapping("/api/v1/policy-metadata/android-runtime-permissions")
  ResponseEntity<Catalog> list() {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(new Catalog(1, AndroidRuntimePermissions.names()));
  }

  record Catalog(int schemaVersion, List<String> permissions) {}
}
