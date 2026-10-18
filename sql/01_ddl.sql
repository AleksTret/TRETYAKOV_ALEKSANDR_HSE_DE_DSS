-- =============================================================
-- Data Vault в Greenplum 6.x
-- Датасет: SampleSuperstore.csv
-- Схема: dv
-- =============================================================
--
-- СОГЛАШЕНИЯ:
--   *_hk        — хэш-ключ MD5 (CHAR(32)), суррогатный ключ DV
--   *_bk        — бизнес-ключ (натуральный)
--   load_date   — момент загрузки (TIMESTAMP)
--   record_source — источник данных (VARCHAR)
--   hash_diff   — MD5 от конкатенации атрибутов (для детекта изменений)
--
-- ОГРАНИЧЕНИЕ ДАТАСЕТА:
--   В SampleSuperstore.csv нет явных ID (customer_id, product_id,
--   order_id). Поэтому бизнес-ключи — композитные, из описательных
--   полей. 
--
--   UNIQUE-ограничение и DISTRIBUTED BY совместимы только если
--   колонки DISTRIBUTED BY входят в UNIQUE. Xабы распределяются 
--   по *_hk в данном случае (для локальных JOIN'ов), поэтому UNIQUE на *_bk
--   не ставим. Защита от дублей — PRIMARY KEY на *_hk +
--   WHERE NOT EXISTS при загрузке (GP 6 = PG 9.4, ON CONFLICT недоступен).
-- =============================================================

CREATE SCHEMA IF NOT EXISTS dv;

COMMENT ON SCHEMA dv IS 'Data Vault: хабы, линки, спутники + фактовая таблица (Data Mart)';

-- =============================================================
-- ХАБЫ
-- =============================================================

-- -------------------------------------------------------------
-- hub_customer
-- Бизнес-ключ: Segment | City | State | Postal Code | Country
-- Обоснование: в датасете нет customer_id, поэтому клиент
-- идентифицируется комбинацией сегмента и географии.
-- -------------------------------------------------------------
CREATE TABLE dv.hub_customer (
    customer_hk    CHAR(32)     NOT NULL,
    customer_bk    TEXT         NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_hub_customer PRIMARY KEY (customer_hk)
)
DISTRIBUTED BY (customer_hk);

COMMENT ON TABLE  dv.hub_customer IS 'Хаб клиентов: уникальные композитные бизнес-ключи';
COMMENT ON COLUMN dv.hub_customer.customer_hk IS 'MD5(segment|city|state|postal_code|country)';
COMMENT ON COLUMN dv.hub_customer.customer_bk IS 'Композитный BK: segment|city|state|postal_code|country';

-- -------------------------------------------------------------
-- hub_product
-- Бизнес-ключ: Category | Sub-Category
-- -------------------------------------------------------------
CREATE TABLE dv.hub_product (
    product_hk     CHAR(32)     NOT NULL,
    product_bk     TEXT         NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_hub_product PRIMARY KEY (product_hk)
)
DISTRIBUTED BY (product_hk);

COMMENT ON TABLE  dv.hub_product IS 'Хаб товаров: категория + подкатегория';
COMMENT ON COLUMN dv.hub_product.product_hk IS 'MD5(category|sub_category)';
COMMENT ON COLUMN dv.hub_product.product_bk IS 'Композитный BK: category|sub_category';

-- -------------------------------------------------------------
-- hub_order
-- Бизнес-ключ: Ship Mode | Postal Code | Sales | Quantity | Discount
-- Обоснование: в датасете нет order_id. Строка = заказ (принятое
-- упрощение). Surrogate BK из комбинации полей строки.
-- ОГРАНИЧЕНИЕ: возможны коллизии для двух разных строк с
-- одинаковыми значениями этих полей
-- -------------------------------------------------------------
CREATE TABLE dv.hub_order (
    order_hk       CHAR(32)     NOT NULL,
    order_bk       TEXT         NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_hub_order PRIMARY KEY (order_hk)
)
DISTRIBUTED BY (order_hk);

COMMENT ON TABLE  dv.hub_order IS 'Хаб заказов: surrogate BK (строка = заказ)';
COMMENT ON COLUMN dv.hub_order.order_hk IS 'MD5(ship_mode|postal_code|sales|quantity|discount)';
COMMENT ON COLUMN dv.hub_order.order_bk IS 'Композитный BK: ship_mode|postal_code|sales|quantity|discount';

-- -------------------------------------------------------------
-- hub_geography
-- Бизнес-ключ: City | State | Postal Code | Country
-- -------------------------------------------------------------
CREATE TABLE dv.hub_geography (
    geography_hk   CHAR(32)     NOT NULL,
    geography_bk   TEXT         NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_hub_geography PRIMARY KEY (geography_hk)
)
DISTRIBUTED BY (geography_hk);

COMMENT ON TABLE  dv.hub_geography IS 'Хаб географии: город + штат + индекс + страна';
COMMENT ON COLUMN dv.hub_geography.geography_hk IS 'MD5(city|state|postal_code|country)';
COMMENT ON COLUMN dv.hub_geography.geography_bk IS 'Композитный BK: city|state|postal_code|country';

-- =============================================================
-- ЛИНКИ
-- =============================================================

CREATE TABLE dv.link_order_customer (
    link_order_customer_hk CHAR(32)     NOT NULL,
    order_hk               CHAR(32)     NOT NULL,
    customer_hk            CHAR(32)     NOT NULL,
    load_date              TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source          VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_link_order_customer PRIMARY KEY (link_order_customer_hk),
    CONSTRAINT fk_loc_order    FOREIGN KEY (order_hk)    REFERENCES dv.hub_order(order_hk),
    CONSTRAINT fk_loc_customer FOREIGN KEY (customer_hk) REFERENCES dv.hub_customer(customer_hk)
)
DISTRIBUTED BY (link_order_customer_hk);

COMMENT ON TABLE dv.link_order_customer IS 'Линк: заказ ↔ клиент (кто сделал заказ)';

CREATE TABLE dv.link_order_product (
    link_order_product_hk CHAR(32)     NOT NULL,
    order_hk              CHAR(32)     NOT NULL,
    product_hk            CHAR(32)     NOT NULL,
    load_date             TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source         VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_link_order_product PRIMARY KEY (link_order_product_hk),
    CONSTRAINT fk_lop_order   FOREIGN KEY (order_hk)   REFERENCES dv.hub_order(order_hk),
    CONSTRAINT fk_lop_product FOREIGN KEY (product_hk) REFERENCES dv.hub_product(product_hk)
)
DISTRIBUTED BY (link_order_product_hk);

COMMENT ON TABLE dv.link_order_product IS 'Линк: заказ ↔ товар (что заказано)';

CREATE TABLE dv.link_order_geography (
    link_order_geography_hk CHAR(32)     NOT NULL,
    order_hk                CHAR(32)     NOT NULL,
    geography_hk            CHAR(32)     NOT NULL,
    load_date               TIMESTAMP    NOT NULL DEFAULT NOW(),
    record_source           VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_link_order_geography PRIMARY KEY (link_order_geography_hk),
    CONSTRAINT fk_log_order     FOREIGN KEY (order_hk)     REFERENCES dv.hub_order(order_hk),
    CONSTRAINT fk_log_geography FOREIGN KEY (geography_hk) REFERENCES dv.hub_geography(geography_hk)
)
DISTRIBUTED BY (link_order_geography_hk);

COMMENT ON TABLE dv.link_order_geography IS 'Линк: заказ ↔ география (куда доставка)';

-- =============================================================
-- СПУТНИКИ (insert-only, версионные)
-- PK = (hub_hk, load_date)
-- hash_diff — MD5 от конкатенации атрибутов (для детекта изменений)
-- =============================================================

CREATE TABLE dv.sat_customer_details (
    customer_hk    CHAR(32)     NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    hash_diff      CHAR(32)     NOT NULL,
    segment        VARCHAR(50),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_sat_customer PRIMARY KEY (customer_hk, load_date),
    CONSTRAINT fk_sat_customer FOREIGN KEY (customer_hk) REFERENCES dv.hub_customer(customer_hk)
)
DISTRIBUTED BY (customer_hk);

COMMENT ON TABLE  dv.sat_customer_details IS 'Спутник клиента: сегмент + hash_diff';
COMMENT ON COLUMN dv.sat_customer_details.hash_diff IS 'MD5(segment) — для детекта изменений';

CREATE TABLE dv.sat_product_details (
    product_hk     CHAR(32)     NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    hash_diff      CHAR(32)     NOT NULL,
    category       VARCHAR(100),
    sub_category   VARCHAR(100),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_sat_product PRIMARY KEY (product_hk, load_date),
    CONSTRAINT fk_sat_product FOREIGN KEY (product_hk) REFERENCES dv.hub_product(product_hk)
)
DISTRIBUTED BY (product_hk);

COMMENT ON TABLE  dv.sat_product_details IS 'Спутник товара: категория + подкатегория + hash_diff';
COMMENT ON COLUMN dv.sat_product_details.hash_diff IS 'MD5(category|sub_category)';

CREATE TABLE dv.sat_order_details (
    order_hk       CHAR(32)     NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    hash_diff      CHAR(32)     NOT NULL,
    ship_mode      VARCHAR(50),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_sat_order PRIMARY KEY (order_hk, load_date),
    CONSTRAINT fk_sat_order FOREIGN KEY (order_hk) REFERENCES dv.hub_order(order_hk)
)
DISTRIBUTED BY (order_hk);

COMMENT ON TABLE  dv.sat_order_details IS 'Спутник заказа: ship_mode + hash_diff (меры — в fact_sales)';
COMMENT ON COLUMN dv.sat_order_details.hash_diff IS 'MD5(ship_mode)';

CREATE TABLE dv.sat_geography_details (
    geography_hk   CHAR(32)     NOT NULL,
    load_date      TIMESTAMP    NOT NULL DEFAULT NOW(),
    hash_diff      CHAR(32)     NOT NULL,
    region         VARCHAR(50),
    record_source  VARCHAR(100) NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_sat_geography PRIMARY KEY (geography_hk, load_date),
    CONSTRAINT fk_sat_geography FOREIGN KEY (geography_hk) REFERENCES dv.hub_geography(geography_hk)
)
DISTRIBUTED BY (geography_hk);

COMMENT ON TABLE  dv.sat_geography_details IS 'Спутник географии: регион + hash_diff';
COMMENT ON COLUMN dv.sat_geography_details.hash_diff IS 'MD5(region)';

-- =============================================================
-- ФАКТОВАЯ ТАБЛИЦА (Data Mart поверх Data Vault)
-- Меры вынесены сюда, т.к. в классическом DV меры не живут
-- в спутниках.
-- =============================================================
CREATE TABLE dv.fact_sales (
    order_hk       CHAR(32)       NOT NULL,
    customer_hk    CHAR(32)       NOT NULL,
    product_hk     CHAR(32)       NOT NULL,
    geography_hk   CHAR(32)       NOT NULL,
    sales          NUMERIC(14,4),
    quantity       INTEGER,
    discount       NUMERIC(6,4),
    profit         NUMERIC(14,4),
    load_date      TIMESTAMP      NOT NULL DEFAULT NOW(),
    record_source  VARCHAR(100)   NOT NULL DEFAULT 'SampleSuperstore.csv',
    CONSTRAINT pk_fact_sales PRIMARY KEY (order_hk, customer_hk, product_hk, geography_hk),
    CONSTRAINT fk_fs_order     FOREIGN KEY (order_hk)     REFERENCES dv.hub_order(order_hk),
    CONSTRAINT fk_fs_customer  FOREIGN KEY (customer_hk)  REFERENCES dv.hub_customer(customer_hk),
    CONSTRAINT fk_fs_product   FOREIGN KEY (product_hk)   REFERENCES dv.hub_product(product_hk),
    CONSTRAINT fk_fs_geography FOREIGN KEY (geography_hk) REFERENCES dv.hub_geography(geography_hk)
)
DISTRIBUTED BY (order_hk);

COMMENT ON TABLE  dv.fact_sales IS 'Фактовая таблица продаж: меры Sales/Quantity/Discount/Profit';
COMMENT ON COLUMN dv.fact_sales.sales    IS 'Сумма продажи (NUMERIC, без потерь точности)';
COMMENT ON COLUMN dv.fact_sales.quantity IS 'Количество единиц';
COMMENT ON COLUMN dv.fact_sales.discount IS 'Скидка (0..1)';
COMMENT ON COLUMN dv.fact_sales.profit   IS 'Прибыль';