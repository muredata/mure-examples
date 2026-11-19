"""Shared DuckDB setup for the UI server and the TPC-DS loader.

Every setting comes from environment variables that the ECS task definition sets
(see terraform/ecs.tf). Nothing here holds credentials: DuckDB uses the AWS
credential chain, which on Fargate resolves to the task role.
"""

from __future__ import annotations

import logging
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import duckdb

log = logging.getLogger("duckdb-app")

# Extensions are installed into the image at build time; nothing is downloaded at runtime.
EXTENSION_DIR = "/opt/duckdb/extensions"
REQUIRED_EXTENSIONS = ("httpfs", "aws", "avro", "iceberg")

_IDENT = re.compile(r"^[a-z][a-z0-9_]{0,254}$")
_ARN = re.compile(r"^arn:aws[a-z-]*:s3tables:[a-z0-9-]+:\d{12}:bucket/[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
_REGION = re.compile(r"^[a-z]{2}(-[a-z]+)+-\d$")
_SIZE = re.compile(r"^\d+(\.\d+)?\s*(KB|MB|GB|TB|KiB|MiB|GiB|TiB)$")


def setup_logging() -> None:
    logging.basicConfig(
        stream=sys.stdout,
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"missing required environment variable {name}")
    return value


def _size(name: str, default: str) -> str:
    value = _env(name, default)
    if not _SIZE.match(value):
        raise SystemExit(f"{name}={value!r} is not a size like '24GB'")
    return value


@dataclass(frozen=True)
class Settings:
    region: str
    table_bucket_arn: str
    namespace: str
    catalog_alias: str
    data_dir: Path
    memory_limit: str
    threads: int
    max_temp_size: str

    @classmethod
    def from_env(cls) -> "Settings":
        arn = _env("TABLE_BUCKET_ARN")
        if not _ARN.match(arn):
            raise SystemExit(f"TABLE_BUCKET_ARN={arn!r} is not an S3 table bucket ARN")
        namespace = _env("S3TABLES_NAMESPACE", "tpcds")
        alias = _env("CATALOG_ALIAS", "lake")
        for name, value in (("S3TABLES_NAMESPACE", namespace), ("CATALOG_ALIAS", alias)):
            if not _IDENT.match(value):
                raise SystemExit(f"{name}={value!r} must match {_IDENT.pattern}")
        region = _env("AWS_REGION")
        if not _REGION.match(region):
            raise SystemExit(f"AWS_REGION={region!r} is not an AWS Region name")
        return cls(
            region=region,
            table_bucket_arn=arn,
            namespace=namespace,
            catalog_alias=alias,
            data_dir=Path(_env("DATA_DIR", "/data")),
            memory_limit=_size("DUCKDB_MEMORY_LIMIT", "24GB"),
            threads=int(_env("DUCKDB_THREADS", str(os.cpu_count() or 4))),
            max_temp_size=_size("DUCKDB_MAX_TEMP_SIZE", "40GB"),
        )


def check_writable(path: Path) -> None:
    """The root filesystem is read-only; fail early and clearly if the data volume is not writable."""
    path.mkdir(parents=True, exist_ok=True)
    probe = path / ".write-probe"
    try:
        probe.write_text("ok")
        probe.unlink()
    except OSError as exc:
        raise SystemExit(f"data directory {path} is not writable: {exc}") from exc


def connect(settings: Settings, database: Path) -> duckdb.DuckDBPyConnection:
    """Open a disk-backed database with settings sized for the Fargate task."""
    temp_dir = settings.data_dir / "tmp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    config = {
        # Resources: leave headroom for the Python process, the UI and the HTTP buffers.
        "memory_limit": settings.memory_limit,
        "threads": settings.threads,
        "temp_directory": str(temp_dir),
        "max_temp_directory_size": settings.max_temp_size,
        # Supply chain: only the signed core extensions baked into the image.
        "extension_directory": EXTENSION_DIR,
        "autoinstall_known_extensions": False,
        "autoload_known_extensions": True,
        "allow_community_extensions": False,
        "allow_unsigned_extensions": False,
        # Analytics over object storage: no ordering guarantees needed, cache metadata and data blocks.
        "preserve_insertion_order": False,
        "parquet_metadata_cache": True,
        "enable_http_metadata_cache": True,
        "enable_external_file_cache": True,
    }
    con = duckdb.connect(str(database), config=config)
    for ext in REQUIRED_EXTENSIONS:
        con.load_extension(ext)
    con.execute("SET http_timeout = 60")
    con.execute("SET http_retries = 5")
    return con


def attach_s3_tables(con: duckdb.DuckDBPyConnection, settings: Settings, attempts: int = 6) -> None:
    """Attach the S3 table bucket through the S3 Tables Iceberg REST endpoint (SigV4, task role)."""
    # CREATE SECRET and ATTACH don't take prepared parameters; every interpolated value was
    # validated against a strict pattern in Settings.from_env.
    con.execute(
        "CREATE OR REPLACE SECRET task_role "
        f"(TYPE s3, PROVIDER credential_chain, REGION '{settings.region}', REFRESH auto)"
    )
    statement = (
        f"ATTACH '{settings.table_bucket_arn}' AS {settings.catalog_alias} "
        "(TYPE iceberg, ENDPOINT_TYPE s3_tables)"
    )
    for attempt in range(1, attempts + 1):
        try:
            con.execute(statement)
            log.info("attached %s as %s", settings.table_bucket_arn, settings.catalog_alias)
            return
        except duckdb.Error as exc:
            if attempt == attempts:
                raise
            wait = min(2**attempt, 30)
            log.warning("attach failed (attempt %d/%d): %s; retrying in %ss", attempt, attempts, exc, wait)
            time.sleep(wait)
