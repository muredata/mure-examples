"""Generate TPC-DS with DuckDB's dsdgen and load it into Amazon S3 Tables.

Runs as a one-off Fargate task (`uv run duckdemo load-tpcds`). Steps:
1. Generate all 24 TPC-DS tables into a disk-backed DuckDB file on the task's
   ephemeral storage (spills to disk instead of running out of memory).
2. For each table: create the Iceberg table through the S3 Tables Iceberg REST
   endpoint with an explicit schema (the endpoint doesn't support stage-create,
   which CTAS needs), then INSERT the rows, sorted by the date key of fact tables
   so Iceberg min/max statistics prune files on date filters.
3. Verify row counts.
"""

from __future__ import annotations

import argparse
import logging
import time

from .common import Settings, attach_s3_tables, check_writable, connect, setup_logging

log = logging.getLogger("duckdb-app.loader")

# Sort key per fact table: gives tight per-file min/max ranges on the date dimension.
SORT_KEYS = {
    "store_sales": "ss_sold_date_sk",
    "store_returns": "sr_returned_date_sk",
    "catalog_sales": "cs_sold_date_sk",
    "catalog_returns": "cr_returned_date_sk",
    "web_sales": "ws_sold_date_sk",
    "web_returns": "wr_returned_date_sk",
    "inventory": "inv_date_sk",
}
TARGET_FILE_SIZE = 256 * 1024 * 1024  # 256 MiB Parquet files; S3 Tables compaction keeps them healthy


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--scale-factor", type=float, default=10.0, help="TPC-DS scale factor (10 = about 10 GB raw)")
    p.add_argument("--format-version", choices=("2", "3"), default="2",
                   help="Iceberg format version. V2 keeps Amazon Athena able to read the tables.")
    p.add_argument("--replace", action="store_true", help="drop and recreate tables that already exist")
    return p.parse_args()


def main() -> None:
    setup_logging()
    args = parse_args()
    settings = Settings.from_env()
    check_writable(settings.data_dir)
    lake, ns = settings.catalog_alias, settings.namespace

    con = connect(settings, settings.data_dir / "tpcds.duckdb")
    con.load_extension("tpcds")

    started = time.monotonic()
    log.info("generating TPC-DS scale factor %s", args.scale_factor)
    con.execute("CALL dsdgen(sf = ?)", [args.scale_factor])
    log.info("generated in %.0fs", time.monotonic() - started)

    attach_s3_tables(con, settings)
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {lake}.{ns}")
    existing = {
        r[0]
        for r in con.execute(
            "SELECT table_name FROM duckdb_tables() WHERE database_name = ? AND schema_name = ?", [lake, ns]
        ).fetchall()
    }
    tables = [
        r[0]
        for r in con.execute(
            "SELECT table_name FROM duckdb_tables() WHERE database_name = current_database() "
            "AND schema_name = 'main' ORDER BY estimated_size DESC"
        ).fetchall()
    ]

    for table in tables:
        t0 = time.monotonic()
        target = f"{lake}.{ns}.{table}"
        if table in existing:
            if not args.replace:
                log.info("skipping %s: already exists (use --replace to reload)", target)
                continue
            con.execute(f"DROP TABLE {target}")
        columns = con.execute(f'DESCRIBE main."{table}"').fetchall()
        column_ddl = ", ".join(f'"{name}" {ctype}' for name, ctype, *_ in columns)
        con.execute(
            f"CREATE TABLE {target} ({column_ddl}) WITH ("
            f"'format-version' = '{args.format_version}', "
            f"'write.target-file-size-bytes' = '{TARGET_FILE_SIZE}', "
            "'write.parquet.compression-codec' = 'zstd')"
        )
        order = f' ORDER BY "{SORT_KEYS[table]}"' if table in SORT_KEYS else ""
        con.execute(f'INSERT INTO {target} SELECT * FROM main."{table}"{order}')
        src = con.execute(f'SELECT count(*) FROM main."{table}"').fetchone()[0]
        dst = con.execute(f"SELECT count(*) FROM {target}").fetchone()[0]
        if src != dst:
            raise SystemExit(f"row count mismatch for {target}: source {src}, Iceberg {dst}")
        log.info("loaded %-24s %12d rows in %5.0fs", table, dst, time.monotonic() - t0)

    log.info("TPC-DS SF%s loaded into %s in %.0fs", args.scale_factor, settings.table_bucket_arn,
             time.monotonic() - started)


if __name__ == "__main__":
    main()
