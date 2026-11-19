"""Seed example notebooks into the DuckDB UI.

The UI stores notebooks in $HOME/.duckdb/extension_data/ui/ui.db (tables
`notebooks` and `notebook_versions`, one JSON document per version). The schema
below matches what DuckDB UI 2.0 creates itself. Seeding runs before
start_ui_server() and only inserts notebooks that are missing, so notebooks a
user edited during the life of the task are kept.

Note: Fargate ephemeral storage is wiped when the task is replaced, so user
notebooks only live as long as the task. Mount Amazon EFS at /data/home to keep them.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

import duckdb

log = logging.getLogger("duckdb-app.notebooks")

_DIR = Path(__file__).parent
_NAMESPACE_UUID = uuid.UUID("6f1d3c3e-6d1a-4f0e-9a39-1c7c5d2b9e10")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS current_notebook_id(id UUID NOT NULL);
CREATE TABLE IF NOT EXISTS has_onboarded(has_onboarded BOOLEAN);
CREATE TABLE IF NOT EXISTS notebooks(id UUID PRIMARY KEY, "name" VARCHAR NOT NULL, created TIMESTAMP NOT NULL);
CREATE TABLE IF NOT EXISTS notebook_versions(
    notebook_id UUID, "version" INTEGER, title VARCHAR NOT NULL, "json" VARCHAR NOT NULL,
    created TIMESTAMP NOT NULL, expires TIMESTAMP, PRIMARY KEY(notebook_id, "version"));
"""


def _parse(path: Path, tokens: dict[str, str]) -> tuple[str, list[str]]:
    text = path.read_text()
    for key, value in tokens.items():
        text = text.replace("{{" + key + "}}", value)
    header, *cells = text.split("-- @cell\n")
    title = path.stem
    for line in header.splitlines():
        if line.startswith("-- @title "):
            title = line.removeprefix("-- @title ").strip()
    return title, [c.strip() for c in cells if c.strip()]


def seed(home: Path, catalog: str, namespace: str) -> None:
    ui_dir = home / ".duckdb" / "extension_data" / "ui"
    ui_dir.mkdir(parents=True, exist_ok=True)
    tokens = {"lake": catalog, "ns": namespace, "db": f"{catalog}.{namespace}"}
    now = datetime.now(timezone.utc).replace(tzinfo=None)

    con = duckdb.connect(str(ui_dir / "ui.db"))
    try:
        con.execute(_SCHEMA)
        first_id = None
        for path in sorted(_DIR.glob("*.sql")):
            title, cells = _parse(path, tokens)
            nb_id = uuid.uuid5(_NAMESPACE_UUID, path.stem)
            first_id = first_id or nb_id
            if con.execute("SELECT 1 FROM notebooks WHERE id = ?", [nb_id]).fetchone():
                continue
            doc = {
                "cells": [
                    {"query": sql, "useDatabase": catalog, "cellId": i, "isActive": i == 1}
                    for i, sql in enumerate(cells, start=1)
                ],
                "currentDatabase": catalog,
                "viewMode": {"mode": "default"},
                "version": 1,
                "notebookSerializationFormat": 3,
            }
            con.execute("INSERT INTO notebooks VALUES (?, ?, ?)", [nb_id, f"notebook_{nb_id.hex[:12]}", now])
            con.execute("INSERT INTO notebook_versions VALUES (?, 1, ?, ?, ?, NULL)",
                        [nb_id, title, json.dumps(doc), now])
            log.info("seeded notebook %r with %d cells", title, len(cells))
        # Open the example notebook on first visit instead of the onboarding screen.
        if first_id and not con.execute("SELECT 1 FROM current_notebook_id").fetchone():
            con.execute("INSERT INTO current_notebook_id VALUES (?)", [first_id])
        if not con.execute("SELECT 1 FROM has_onboarded").fetchone():
            con.execute("INSERT INTO has_onboarded VALUES (true)")
    finally:
        con.close()
