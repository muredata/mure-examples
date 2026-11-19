# syntax=docker/dockerfile:1.7
# HAProxy sidecar that exposes the loopback-only DuckDB UI to the ALB on :8080.
FROM public.ecr.aws/docker/library/haproxy:3.2-alpine
COPY --chown=root:root haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
# The official image already runs as the unprivileged "haproxy" user; port 8080 needs no capabilities.
USER haproxy
EXPOSE 8080
RUN haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
