"""Long-running DuckDB process that serves the DuckDB UI on localhost:4213.

The UI listens on loopback only. The HAProxy sidecar in the same task (shared
network namespace) is the only thing that reaches it; see images/proxy.
"""

from __future__ import annotations

import logging
import os
import signal
import threading
from pathlib import Path

from . import notebooks
from .common import Settings, attach_s3_tables, check_writable, connect, setup_logging

log = logging.getLogger("duckdb-app.server")


def main() -> None:
    setup_logging()
    settings = Settings.from_env()
    check_writable(settings.data_dir)
    # The UI keeps notebooks under $HOME/.duckdb/extension_data/ui; HOME points at the data volume.
    os.makedirs(os.path.expanduser("~/.duckdb"), exist_ok=True)

    con = connect(settings, settings.data_dir / "workspace.duckdb")
    con.load_extension("ui")

    lake, ns = settings.catalog_alias, settings.namespace
    if os.environ.get("SKIP_S3TABLES_ATTACH_FOR_LOCAL_TEST") == "1":
        # Local smoke test without AWS: a tiny in-memory TPC-DS under the same names.
        log.warning("SKIP_S3TABLES_ATTACH_FOR_LOCAL_TEST=1: using in-memory TPC-DS SF0.01 (local test only)")
        con.load_extension("tpcds")
        con.execute(f"ATTACH ':memory:' AS {lake}")
        con.execute(f"CREATE SCHEMA {lake}.{ns}")
        con.execute(f"CREATE SCHEMA {lake}.sandbox")
        con.execute("CALL dsdgen(sf = 0.01, catalog = ?, schema = ?)", [lake, ns])
    else:
        attach_s3_tables(con, settings)
    con.execute(f"USE {lake}.{ns}")
    # tpcds_queries() in the example notebook needs the tpcds extension (baked into the image).
    con.load_extension("tpcds")

    notebooks.seed(Path(os.path.expanduser("~")), lake, ns)

    con.execute("SET ui_local_port = 4213")
    # After this point a UI user can't change engine settings (memory, extensions, file cache...).
    con.execute("SET lock_configuration = true")
    con.execute("CALL start_ui_server()")
    log.info("DuckDB UI server listening on localhost:4213 (loopback only)")

    stop = threading.Event()

    def _shutdown(signum, _frame):
        log.info("received signal %s, stopping", signum)
        stop.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    stop.wait()
    try:
        con.execute("CALL stop_ui_server()")
    finally:
        con.close()
    log.info("stopped")


if __name__ == "__main__":
    main()
