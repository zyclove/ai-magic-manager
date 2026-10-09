package com.aimanager;

import org.junit.jupiter.api.Test;
import org.springframework.modulith.core.ApplicationModules;

class ModuleBoundariesTest {
    @Test void domainModulesHaveNoCyclesOrInternalPackageDependencies() {
        ApplicationModules.of(ManagerApplication.class).verify();
    }
}
