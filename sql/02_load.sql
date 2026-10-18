-- =============================================================
-- Итоговое задание, модуль 1
-- Загрузка SampleSuperstore.csv в схему dv (Data Vault)
-- =============================================================
--
-- ВАЖНО: Greenplum 6.x основан на PostgreSQL 9.4, где НЕТ
-- синтаксиса INSERT ... ON CONFLICT (появился в PG 9.5).
-- Поэтому идемпотентность обеспечивается через WHERE NOT EXISTS.
--
-- ПОРЯДОК:
--   1. staging-таблица + COPY из CSV
--   2. хабы          (order → customer → product → geography)
--   3. линки         (после хабов)
--   4. спутники      (после хабов)
--   5. фактовая таблица (после всех)
-- =============================================================

-- =============================================================
-- 1. STAGING
-- =============================================================

DROP TABLE IF EXISTS dv.stg_superstore;

CREATE TABLE dv.stg_superstore (
    ship_mode      TEXT,
    segment        TEXT,
    country        TEXT,
    city           TEXT,
    state          TEXT,
    postal_code    TEXT,
    region         TEXT,
    category       TEXT,
    sub_category   TEXT,
    sales          NUMERIC(14,4),
    quantity       INTEGER,
    discount       NUMERIC(6,4),
    profit         NUMERIC(14,4)
)
DISTRIBUTED RANDOMLY;

COMMENT ON TABLE dv.stg_superstore IS 'Staging: сырые данные из SampleSuperstore.csv';

COPY dv.stg_superstore (
    ship_mode, segment, country, city, state, postal_code, region,
    category, sub_category, sales, quantity, discount, profit
)
FROM '/data/SampleSuperstore.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', NULL '');

-- =============================================================
-- 2. ХАБЫ
-- =============================================================

-- -------------------------------------------------------------
-- hub_order
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(
               COALESCE(ship_mode, '')   || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(sales::text, '') || '|' ||
               COALESCE(quantity::text, '') || '|' ||
               COALESCE(discount::text, '')
           )::char(32)                                       AS order_hk,
           COALESCE(ship_mode, '')   || '|' ||
           COALESCE(postal_code, '') || '|' ||
           COALESCE(sales::text, '') || '|' ||
           COALESCE(quantity::text, '') || '|' ||
           COALESCE(discount::text, '')                      AS order_bk
    FROM dv.stg_superstore
)
INSERT INTO dv.hub_order (order_hk, order_bk, load_date, record_source)
SELECT src.order_hk, src.order_bk, NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.hub_order h WHERE h.order_hk = src.order_hk
);

-- -------------------------------------------------------------
-- hub_customer
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(
               COALESCE(segment, '')     || '|' ||
               COALESCE(city, '')        || '|' ||
               COALESCE(state, '')       || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(country, '')
           )::char(32)                                       AS customer_hk,
           COALESCE(segment, '')     || '|' ||
           COALESCE(city, '')        || '|' ||
           COALESCE(state, '')       || '|' ||
           COALESCE(postal_code, '') || '|' ||
           COALESCE(country, '')                             AS customer_bk
    FROM dv.stg_superstore
)
INSERT INTO dv.hub_customer (customer_hk, customer_bk, load_date, record_source)
SELECT src.customer_hk, src.customer_bk, NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.hub_customer h WHERE h.customer_hk = src.customer_hk
);

-- -------------------------------------------------------------
-- hub_product
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(
               COALESCE(category, '')     || '|' ||
               COALESCE(sub_category, '')
           )::char(32)                                       AS product_hk,
           COALESCE(category, '')     || '|' ||
           COALESCE(sub_category, '')                        AS product_bk
    FROM dv.stg_superstore
)
INSERT INTO dv.hub_product (product_hk, product_bk, load_date, record_source)
SELECT src.product_hk, src.product_bk, NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.hub_product h WHERE h.product_hk = src.product_hk
);

-- -------------------------------------------------------------
-- hub_geography
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(
               COALESCE(city, '')        || '|' ||
               COALESCE(state, '')       || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(country, '')
           )::char(32)                                       AS geography_hk,
           COALESCE(city, '')        || '|' ||
           COALESCE(state, '')       || '|' ||
           COALESCE(postal_code, '') || '|' ||
           COALESCE(country, '')                             AS geography_bk
    FROM dv.stg_superstore
)
INSERT INTO dv.hub_geography (geography_hk, geography_bk, load_date, record_source)
SELECT src.geography_hk, src.geography_bk, NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.hub_geography h WHERE h.geography_hk = src.geography_hk
);

-- =============================================================
-- 3. ЛИНКИ
-- =============================================================

-- -------------------------------------------------------------
-- link_order_customer
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(order_hk || customer_hk)::char(32)            AS link_order_customer_hk,
           order_hk,
           customer_hk
    FROM (
        SELECT
            MD5(COALESCE(ship_mode, '')   || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(sales::text, '') || '|' ||
                COALESCE(quantity::text, '') || '|' ||
                COALESCE(discount::text, ''))::char(32) AS order_hk,
            MD5(COALESCE(segment, '')     || '|' ||
                COALESCE(city, '')        || '|' ||
                COALESCE(state, '')       || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(country, ''))::char(32)        AS customer_hk
        FROM dv.stg_superstore
    ) x
)
INSERT INTO dv.link_order_customer (
    link_order_customer_hk, order_hk, customer_hk, load_date, record_source
)
SELECT src.link_order_customer_hk, src.order_hk, src.customer_hk,
       NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.link_order_customer l
    WHERE l.link_order_customer_hk = src.link_order_customer_hk
);

-- -------------------------------------------------------------
-- link_order_product
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(order_hk || product_hk)::char(32)             AS link_order_product_hk,
           order_hk,
           product_hk
    FROM (
        SELECT
            MD5(COALESCE(ship_mode, '')   || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(sales::text, '') || '|' ||
                COALESCE(quantity::text, '') || '|' ||
                COALESCE(discount::text, ''))::char(32) AS order_hk,
            MD5(COALESCE(category, '')     || '|' ||
                COALESCE(sub_category, ''))::char(32)   AS product_hk
        FROM dv.stg_superstore
    ) x
)
INSERT INTO dv.link_order_product (
    link_order_product_hk, order_hk, product_hk, load_date, record_source
)
SELECT src.link_order_product_hk, src.order_hk, src.product_hk,
       NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.link_order_product l
    WHERE l.link_order_product_hk = src.link_order_product_hk
);

-- -------------------------------------------------------------
-- link_order_geography
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(order_hk || geography_hk)::char(32)           AS link_order_geography_hk,
           order_hk,
           geography_hk
    FROM (
        SELECT
            MD5(COALESCE(ship_mode, '')   || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(sales::text, '') || '|' ||
                COALESCE(quantity::text, '') || '|' ||
                COALESCE(discount::text, ''))::char(32) AS order_hk,
            MD5(COALESCE(city, '')        || '|' ||
                COALESCE(state, '')       || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(country, ''))::char(32)        AS geography_hk
        FROM dv.stg_superstore
    ) x
)
INSERT INTO dv.link_order_geography (
    link_order_geography_hk, order_hk, geography_hk, load_date, record_source
)
SELECT src.link_order_geography_hk, src.order_hk, src.geography_hk,
       NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.link_order_geography l
    WHERE l.link_order_geography_hk = src.link_order_geography_hk
);

-- =============================================================
-- 4. СПУТНИКИ
-- Первая загрузка: все уникальные версии.
-- Повторный запуск в тот же момент времени не создаст дублей
-- (PK = (hk, load_date), WHERE NOT EXISTS по этому PK).
-- =============================================================

-- -------------------------------------------------------------
-- sat_customer_details
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(COALESCE(segment, '')     || '|' ||
               COALESCE(city, '')        || '|' ||
               COALESCE(state, '')       || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(country, ''))::char(32)             AS customer_hk,
           NOW()                                            AS load_date,
           MD5(COALESCE(segment, ''))::char(32)             AS hash_diff,
           segment
    FROM dv.stg_superstore
)
INSERT INTO dv.sat_customer_details (
    customer_hk, load_date, hash_diff, segment, record_source
)
SELECT src.customer_hk, src.load_date, src.hash_diff, src.segment,
       'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.sat_customer_details d
    WHERE d.customer_hk = src.customer_hk
      AND d.load_date   = src.load_date
);

-- -------------------------------------------------------------
-- sat_product_details
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(COALESCE(category, '')     || '|' ||
               COALESCE(sub_category, ''))::char(32)        AS product_hk,
           NOW()                                            AS load_date,
           MD5(COALESCE(category, '')     || '|' ||
               COALESCE(sub_category, ''))::char(32)        AS hash_diff,
           category,
           sub_category
    FROM dv.stg_superstore
)
INSERT INTO dv.sat_product_details (
    product_hk, load_date, hash_diff, category, sub_category, record_source
)
SELECT src.product_hk, src.load_date, src.hash_diff,
       src.category, src.sub_category, 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.sat_product_details d
    WHERE d.product_hk = src.product_hk
      AND d.load_date  = src.load_date
);

-- -------------------------------------------------------------
-- sat_order_details
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(COALESCE(ship_mode, '')   || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(sales::text, '') || '|' ||
               COALESCE(quantity::text, '') || '|' ||
               COALESCE(discount::text, ''))::char(32)      AS order_hk,
           NOW()                                            AS load_date,
           MD5(COALESCE(ship_mode, ''))::char(32)           AS hash_diff,
           ship_mode
    FROM dv.stg_superstore
)
INSERT INTO dv.sat_order_details (
    order_hk, load_date, hash_diff, ship_mode, record_source
)
SELECT src.order_hk, src.load_date, src.hash_diff, src.ship_mode,
       'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.sat_order_details d
    WHERE d.order_hk  = src.order_hk
      AND d.load_date = src.load_date
);

-- -------------------------------------------------------------
-- sat_geography_details
-- -------------------------------------------------------------
WITH src AS (
    SELECT DISTINCT
           MD5(COALESCE(city, '')        || '|' ||
               COALESCE(state, '')       || '|' ||
               COALESCE(postal_code, '') || '|' ||
               COALESCE(country, ''))::char(32)             AS geography_hk,
           NOW()                                            AS load_date,
           MD5(COALESCE(region, ''))::char(32)              AS hash_diff,
           region
    FROM dv.stg_superstore
)
INSERT INTO dv.sat_geography_details (
    geography_hk, load_date, hash_diff, region, record_source
)
SELECT src.geography_hk, src.load_date, src.hash_diff, src.region,
       'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.sat_geography_details d
    WHERE d.geography_hk = src.geography_hk
      AND d.load_date    = src.load_date
);

-- =============================================================
-- 5. ФАКТОВАЯ ТАБЛИЦА (Data Mart)
-- =============================================================
-- DISTINCT ON (...) — оставляем ровно одну строку на PK.
-- Это осознанное упрощение: surrogate BK hub_order может дать
-- коллизии (две разные строки с одинаковыми ship_mode|postal_code|
-- sales|quantity|discount, но разным profit). В проме желательно
-- order_id.
WITH src AS (
    SELECT DISTINCT ON (order_hk, customer_hk, product_hk, geography_hk)
           order_hk, customer_hk, product_hk, geography_hk,
           sales, quantity, discount, profit
    FROM (
        SELECT
            MD5(COALESCE(ship_mode, '')   || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(sales::text, '') || '|' ||
                COALESCE(quantity::text, '') || '|' ||
                COALESCE(discount::text, ''))::char(32) AS order_hk,
            MD5(COALESCE(segment, '')     || '|' ||
                COALESCE(city, '')        || '|' ||
                COALESCE(state, '')       || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(country, ''))::char(32)        AS customer_hk,
            MD5(COALESCE(category, '')     || '|' ||
                COALESCE(sub_category, ''))::char(32)   AS product_hk,
            MD5(COALESCE(city, '')        || '|' ||
                COALESCE(state, '')       || '|' ||
                COALESCE(postal_code, '') || '|' ||
                COALESCE(country, ''))::char(32)        AS geography_hk,
            sales, quantity, discount, profit
        FROM dv.stg_superstore
    ) x
    ORDER BY order_hk, customer_hk, product_hk, geography_hk,
             profit DESC NULLS LAST
)
INSERT INTO dv.fact_sales (
    order_hk, customer_hk, product_hk, geography_hk,
    sales, quantity, discount, profit,
    load_date, record_source
)
SELECT src.order_hk, src.customer_hk, src.product_hk, src.geography_hk,
       src.sales, src.quantity, src.discount, src.profit,
       NOW(), 'SampleSuperstore.csv'
FROM src
WHERE NOT EXISTS (
    SELECT 1 FROM dv.fact_sales f
    WHERE f.order_hk     = src.order_hk
      AND f.customer_hk  = src.customer_hk
      AND f.product_hk   = src.product_hk
      AND f.geography_hk = src.geography_hk
);

-- =============================================================
-- 6. КОНТРОЛЬНЫЕ SELECT'Ы
-- =============================================================
SELECT 'stg_superstore'        AS table_name, COUNT(*) AS rows FROM dv.stg_superstore
UNION ALL SELECT 'hub_order',              COUNT(*) FROM dv.hub_order
UNION ALL SELECT 'hub_customer',           COUNT(*) FROM dv.hub_customer
UNION ALL SELECT 'hub_product',            COUNT(*) FROM dv.hub_product
UNION ALL SELECT 'hub_geography',          COUNT(*) FROM dv.hub_geography
UNION ALL SELECT 'link_order_customer',    COUNT(*) FROM dv.link_order_customer
UNION ALL SELECT 'link_order_product',     COUNT(*) FROM dv.link_order_product
UNION ALL SELECT 'link_order_geography',   COUNT(*) FROM dv.link_order_geography
UNION ALL SELECT 'sat_customer_details',   COUNT(*) FROM dv.sat_customer_details
UNION ALL SELECT 'sat_product_details',    COUNT(*) FROM dv.sat_product_details
UNION ALL SELECT 'sat_order_details',      COUNT(*) FROM dv.sat_order_details
UNION ALL SELECT 'sat_geography_details',  COUNT(*) FROM dv.sat_geography_details
UNION ALL SELECT 'fact_sales',             COUNT(*) FROM dv.fact_sales
ORDER BY table_name;