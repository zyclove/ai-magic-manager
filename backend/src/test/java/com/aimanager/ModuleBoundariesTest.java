package com.aimanager;

import static org.junit.jupiter.api.Assertions.*;

import com.tngtech.archunit.base.DescribedPredicate;
import com.tngtech.archunit.core.domain.JavaClass;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.springframework.modulith.core.ApplicationModules;

class ModuleBoundariesTest {
    @Test void domainModulesHaveNoCyclesOrInternalPackageDependencies() throws Exception {
        var testSource = ModuleBoundariesTest.class.getProtectionDomain().getCodeSource();
        var productionSource = ManagerApplication.class.getProtectionDomain().getCodeSource();
        assertNotNull(testSource, "The current test output must have a CodeSource.");
        assertNotNull(productionSource, "Production classes must have a CodeSource.");
        var testUri = testSource.getLocation().toURI();
        var productionUri = productionSource.getLocation().toURI();
        assertEquals("file", testUri.getScheme(), "The current test output must be a directory.");
        assertEquals("file", productionUri.getScheme(), "Production output must have a file location.");
        var testOutput = Path.of(testUri).toAbsolutePath().normalize();
        var productionOutput = Path.of(productionUri).toAbsolutePath().normalize();
        assertTrue(Files.isDirectory(testOutput), "The current test output directory must exist.");
        assertTrue(Files.isDirectory(productionOutput), "The production output directory must exist.");
        assertFalse(productionOutput.startsWith(testOutput),
            "Excluding the test output must never exclude production classes.");

        // ArchUnit's predefined test patterns do not cover a relocated Maven build directory.
        // Exclude only this run's test output, including helpers and nested fixture classes.
        var currentTestOutput = new DescribedPredicate<JavaClass>("classes from the current test output") {
            @Override public boolean test(JavaClass candidate) {
                return candidate.getSource()
                    .map(source -> source.getUri())
                    .filter(uri -> "file".equals(uri.getScheme()))
                    .map(uri -> Path.of(uri).toAbsolutePath().normalize().startsWith(testOutput))
                    .orElse(false);
            }
        };
        ApplicationModules.of(ManagerApplication.class, currentTestOutput).verify();
    }
}
