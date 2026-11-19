# syntax=docker/dockerfile:1.7
# DuckDB 2.0 + UI + Iceberg for AWS Fargate (linux/arm64, Graviton).
# Build: uv run duckdemo push-images   (or: docker buildx build --platform linux/arm64 .)

ARG PYTHON_IMAGE=public.ecr.aws/docker/library/python:3.13-slim-bookworm

FROM ghcr.io/astral-sh/uv:0.13.7 AS uv

FROM ${PYTHON_IMAGE} AS build
COPY --from=uv /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
# Bake the signed core extensions into the image (the UI also uses autocomplete, icu and json);
# the runtime never downloads extensions.
RUN mkdir -p /opt/duckdb/extensions \
 && /app/.venv/bin/python -c "import duckdb; c = duckdb.connect(config={'extension_directory': '/opt/duckdb/extensions'}); [c.install_extension(e) for e in ('httpfs', 'aws', 'avro', 'iceberg', 'ui', 'autocomplete', 'icu', 'json', 'tpcds')]; print(c.sql(\"select extension_name, extension_version from duckdb_extensions() where installed and install_path like '/opt/%'\").fetchall())"

FROM ${PYTHON_IMAGE}
RUN groupadd --system --gid 10001 duckdb \
 && useradd --system --uid 10001 --gid duckdb --home-dir /data/home --no-create-home duckdb \
 && mkdir -p /data/home \
 && chown -R duckdb:duckdb /data
COPY --from=build --chown=root:root /app/.venv /app/.venv
COPY --from=build --chown=root:root /opt/duckdb /opt/duckdb
COPY --chown=root:root app /app/app
ENV PATH=/app/.venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/data/home \
    DATA_DIR=/data
WORKDIR /app
USER 10001:10001
VOLUME ["/data"]
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:4213/info', timeout=4).status == 200 else 1)"]
CMD ["python", "-m", "app.server"]
