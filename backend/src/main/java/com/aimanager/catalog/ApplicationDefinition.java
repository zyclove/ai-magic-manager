package com.aimanager.catalog;

import com.aimanager.fleet.Device;
import java.util.List;

/** A declared identity, not evidence of installation, safety rating or verified signing lineage. */
public record ApplicationDefinition(String id, String displayName, Device.Platform platform, String packageName,
                                    Profile profile, List<String> signingDigests, String evidenceStatus) {
    public enum Profile { PRIMARY, WORK, SECONDARY, UNKNOWN }
}
