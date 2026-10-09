ARG EDGE_BASE_IMAGE=nginx:1.28-alpine
FROM ${EDGE_BASE_IMAGE}
RUN addgroup -S -g 10001 manager && adduser -S -D -u 10001 -G manager manager && mkdir -p /etc/nginx/includes
COPY --chown=10001:10001 . /usr/share/nginx/html/
USER 10001:10001
EXPOSE 8080 8443
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["nginx", "-g", "daemon off;"]
