-- @title TPC-DS on Amazon S3 Tables (start here)
-- Cells are separated by "-- @cell". Tokens: {{lake}} = attached catalog, {{db}} = catalog.namespace.

-- @cell
-- 1 · Where am I? DuckDB 2.0 on AWS Fargate. Settings are locked, so UI users can't change them.
SELECT version()                              AS duckdb_version,
       current_setting('memory_limit')         AS memory_limit,
       current_setting('threads')              AS threads,
       current_setting('temp_directory')       AS spills_to,
       current_setting('max_temp_directory_size') AS max_spill,
       current_setting('lock_configuration')   AS settings_locked;

-- @cell
-- 2 · The S3 table bucket is attached as "{{lake}}" through the S3 Tables Iceberg REST endpoint (SigV4, task role).
SELECT database_name, type, path
FROM duckdb_databases()
WHERE NOT internal;

-- @cell
-- 3 · The 24 TPC-DS tables, each one an Apache Iceberg table managed by S3 Tables.
SELECT table_name, column_count
FROM duckdb_tables()
WHERE database_name = '{{lake}}' AND schema_name = '{{ns}}'
ORDER BY table_name;

-- @cell
-- 4 · Row counts of the fact tables (scale factor 10: store_sales has about 28.8 million rows).
SELECT 'store_sales' AS fact_table, count(*) AS row_count FROM {{db}}.store_sales
UNION ALL SELECT 'catalog_sales',   count(*) FROM {{db}}.catalog_sales
UNION ALL SELECT 'web_sales',       count(*) FROM {{db}}.web_sales
UNION ALL SELECT 'store_returns',   count(*) FROM {{db}}.store_returns
UNION ALL SELECT 'catalog_returns', count(*) FROM {{db}}.catalog_returns
UNION ALL SELECT 'web_returns',     count(*) FROM {{db}}.web_returns
UNION ALL SELECT 'inventory',       count(*) FROM {{db}}.inventory
ORDER BY row_count DESC;

-- @cell
-- 5 · Iceberg metadata: snapshots of store_sales. Every commit (INSERT, MERGE, compaction) adds one.
FROM iceberg_snapshots({{db}}.store_sales);

-- @cell
-- 6 · Data files behind store_sales. S3 Tables compaction keeps files near the target size.
SELECT count(*)                                         AS files,
       sum(record_count)                                AS rows,
       round(sum(file_size_in_bytes) / 1024 ^ 3, 2)     AS total_gib,
       round(avg(file_size_in_bytes) / 1024 ^ 2)        AS avg_file_mib
FROM iceberg_files({{db}}.store_sales);

-- @cell
-- 7 · Table properties written by the loader: format version, target file size, ZSTD compression.
FROM iceberg_table_properties({{db}}.store_sales);

-- @cell
-- 8 · TPC-DS query 3: brand revenue for one manufacturer in November, by year.
SELECT dt.d_year, item.i_brand_id AS brand_id, item.i_brand AS brand,
       sum(ss_ext_sales_price) AS sum_agg
FROM {{db}}.date_dim dt
JOIN {{db}}.store_sales ON dt.d_date_sk = store_sales.ss_sold_date_sk
JOIN {{db}}.item        ON store_sales.ss_item_sk = item.i_item_sk
WHERE item.i_manufact_id = 128
  AND dt.d_moy = 11
GROUP BY dt.d_year, item.i_brand, item.i_brand_id
ORDER BY dt.d_year, sum_agg DESC, brand_id
LIMIT 100;

-- @cell
-- 9 · Revenue by channel and month for 2002, pivoted for charting (store, catalog and web sales).
PIVOT (
    SELECT d.d_moy AS month, s.channel, s.net_paid
    FROM (
        SELECT 'store' AS channel, ss_sold_date_sk AS date_sk, ss_net_paid AS net_paid FROM {{db}}.store_sales
        UNION ALL
        SELECT 'catalog', cs_sold_date_sk, cs_net_paid FROM {{db}}.catalog_sales
        UNION ALL
        SELECT 'web', ws_sold_date_sk, ws_net_paid FROM {{db}}.web_sales
    ) s
    JOIN {{db}}.date_dim d ON d.d_date_sk = s.date_sk
    WHERE d.d_year = 2002
)
ON channel
USING round(sum(net_paid) / 1e6, 2)
ORDER BY month;

-- @cell
-- 10 · File pruning: store_sales was written sorted by date, so Iceberg min/max statistics let
--      DuckDB skip most data files for a one-month filter. Compare the timing with cell 4.
EXPLAIN ANALYZE
SELECT count(*) AS sales, sum(ss_net_paid) AS net_paid
FROM {{db}}.store_sales
WHERE ss_sold_date_sk BETWEEN 2451545 AND 2451575;  -- January 2000

-- @cell
-- 11 · All 99 official TPC-DS queries ship with the tpcds extension. Copy one into a new cell,
--      prefix the table names with {{db}}. and run it.
SELECT query_nr, query
FROM tpcds_queries()
ORDER BY query_nr;

-- @cell
-- 12 · Writes. The task role can only create and change tables in the "sandbox" namespace;
--      the TPC-DS tables are read-only for the UI.
CREATE TABLE IF NOT EXISTS {{lake}}.sandbox.daily_store_revenue (
    sold_date DATE,
    store_id  VARCHAR,
    revenue   DECIMAL(18, 2)
);

-- @cell
-- 13 · Upsert December 2002 into the sandbox table. DuckDB writes merge-on-read position deletes.
--      Run it twice: the second run updates rows instead of inserting them.
MERGE INTO {{lake}}.sandbox.daily_store_revenue AS t
USING (
    SELECT d.d_date AS sold_date, s.s_store_id AS store_id,
           sum(ss.ss_net_paid)::DECIMAL(18, 2) AS revenue
    FROM {{db}}.store_sales ss
    JOIN {{db}}.date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
    JOIN {{db}}.store s    ON ss.ss_store_sk = s.s_store_sk
    WHERE d.d_year = 2002 AND d.d_moy = 12
    GROUP BY ALL
) AS src
ON t.sold_date = src.sold_date AND t.store_id = src.store_id
WHEN MATCHED THEN UPDATE SET revenue = src.revenue
WHEN NOT MATCHED THEN INSERT VALUES (src.sold_date, src.store_id, src.revenue);

-- @cell
-- 14 · Each MERGE is a new snapshot. Copy a snapshot_id and query an older version with:
--      FROM {{lake}}.sandbox.daily_store_revenue AT (VERSION => <snapshot_id>);
SELECT snapshot_id, sequence_number, timestamp_ms
FROM iceberg_snapshots({{lake}}.sandbox.daily_store_revenue)
ORDER BY sequence_number;
