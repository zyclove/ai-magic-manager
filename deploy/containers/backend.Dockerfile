ARG JAVA_RUNTIME_IMAGE=eclipse-temurin:17-jre-alpine
FROM ${JAVA_RUNTIME_IMAGE}
ARG RELEASE_REVISION
ARG RELEASE_VERSION
ARG RELEASE_MANIFEST_SHA256
ARG RELEASE_SOURCE_TREE_SHA256
ARG RELEASE_ARTIFACT_TREE_SHA256
LABEL org.opencontainers.image.revision="${RELEASE_REVISION}" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      com.aimanager.release.manifest-sha256="${RELEASE_MANIFEST_SHA256}" \
      com.aimanager.release.source-tree-sha256="${RELEASE_SOURCE_TREE_SHA256}" \
      com.aimanager.release.artifact-tree-sha256="${RELEASE_ARTIFACT_TREE_SHA256}"
RUN addgroup -S -g 10001 manager && adduser -S -D -u 10001 -G manager manager
WORKDIR /app
COPY --chown=10001:10001 manager-backend.jar /app/manager-backend.jar
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=45s --retries=12 CMD wget -q -O /dev/null http://127.0.0.1:8080/actuator/health || exit 1
ENTRYPOINT ["java", "-jar", "/app/manager-backend.jar"]
