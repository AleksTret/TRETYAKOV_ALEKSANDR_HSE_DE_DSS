# Итоговый проект по предмету «Системы хранения данных»

**Выполнил - Третьяков Александр Юрьевич**

# Решение


## 1. Инфраструктура

- **СУБД:** Greenplum 6.19.2 (single-node, 2 сегмента) в Docker.
- **Запуск:** `docker compose up -d` (образ `projectairws/greenplum:latest`).
- **Датасет:** `data/SampleSuperstore.csv` (проброшен в контейнер как `/data/...`).
- **SQL-скрипты:** `sql/` (проброшен как `/sql/...`).
- **Подключение:** `docker exec -it -u gpadmin gp_superstore psql -h localhost -U gpadmin -d gpadmin`.

## 2. Анализ датасета

`SampleSuperstore.csv` — плоская денормализованная таблица продаж, 13 колонок:
`Ship Mode, Segment, Country, City, State, Postal Code, Region, Category, Sub-Category, Sales, Quantity, Discount, Profit`.

**Ключевая особенность:** в датасете **нет явных ID** (customer_id, product_id, order_id). Поэтому бизнес-ключи сущностей приходится строить как **композитные** — из комбинаций описательных полей. Это ограничение явно фиксируется в проектировании.

## 3. Проектирование (Data Vault)

### 3.1. Хабы (4)

| Хаб | Бизнес-ключ (BK) | Хэш-ключ | Обоснование |
|---|---|---|---|
| `hub_customer` | `Segment \| City \| State \| Postal Code \| Country` | `MD5(BK)` | Нет customer_id — композитный ключ из сегмента + географии |
| `hub_product` | `Category \| Sub-Category` | `MD5(BK)` | Иерархия товара: категория → подкатегория |
| `hub_order` | `Ship Mode \| Postal Code \| Sales \| Quantity \| Discount` | `MD5(BK)` | Нет order_id — surrogate от комбинации полей строки; строка = заказ |
| `hub_geography` | `City \| State \| Postal Code \| Country` | `MD5(BK)` | География вынесена в отдельный хаб |

### 3.2. Линки (3)

| Линк | Связь | Хэш-ключ |
|---|---|---|
| `link_order_customer` | order ↔ customer | `MD5(order_hk \| customer_hk)` |
| `link_order_product` | order ↔ product | `MD5(order_hk \| product_hk)` |
| `link_order_geography` | order ↔ geography | `MD5(order_hk \| geography_hk)` |

### 3.3. Спутники (4)

| Спутник | Привязка | Атрибуты |
|---|---|---|
| `sat_customer_details` | hub_customer | `Segment` + `hash_diff` |
| `sat_product_details` | hub_product | `Category`, `Sub-Category` + `hash_diff` |
| `sat_order_details` | hub_order | `Ship Mode` + `hash_diff` |
| `sat_geography_details` | hub_geography | `Region` + `hash_diff` |

### 3.4. Фактовая таблица (Data Mart, 1)

| Таблица | Привязка | Меры |
|---|---|---|
| `fact_sales` | order_hk, customer_hk, product_hk, geography_hk | `Sales`, `Quantity`, `Discount`, `Profit` |

### 3.5. Диаграмма связей

```text
hub_customer ──< link_order_customer >── hub_order
hub_product ──< link_order_product >── hub_order
hub_geography ─< link_order_geography >─ hub_order

hub_customer ── sat_customer_details
hub_product ── sat_product_details
hub_order ── sat_order_details
hub_geography ── sat_geography_details

fact_sales ── order_hk, customer_hk, product_hk, geography_hk
```


### 3.6. Ключевые решения проектирования

1. **Хэш-ключи (`MD5`)** вместо натуральных — стандарт Data Vault, стабильный суррогатный ключ.
2. **`load_date + record_source`** в каждом объекте — обязательный аудит загрузки.
3. **Спутники insert-only**, PK = `(hub_hk, load_date)`, `hash_diff` — для детекта изменений.
4. **Композитные BK** — вынужденная мера из-за отсутствия ID в датасете; описана как ограничение.
5. **Ограничение `hub_order`**: surrogate BK (`ship_mode|postal_code|sales|quantity|discount`) может дать коллизии для двух разных строк с одинаковыми значениями — допустимое упрощение для учебной модели.
6. **Меры вынесены в `fact_sales`** — в классическом DV меры не живут в спутниках; фактовая таблица — слой Data Mart поверх DV.
7. **`DISTRIBUTED BY (hub_hk)`** — локальные JOIN'ы на сегментах Greenplum.


# 4. Реализация

**Файлы:**
- DDL: [`sql/01_ddl.sql`](./sql/01_ddl.sql)
- Загрузка: [`sql/02_load.sql`](./sql/02_load.sql)
- Инфраструктура: [`docker-compose.yml`](./docker-compose.yml)

**Создание таблиц**

<img src="./assets/2026-10-18 235951.jpg" width="700">


**Проверка созданных таблиц**

<img src="./assets/2026-10-19 000037.jpg" width="700">

**Загрузка данных**

<img src="./assets/2026-10-19 000939.jpg" width="700">

**Примеры строк из хабов**

<img src="./assets/2026-10-19 002832.jpg" width="700">

**Примеры строк из факта**

<img src="./assets/2026-10-19 002929.jpg" width="700">

**Проверка целостности**

0 — все строки факта имеют соответствующие хабы (несмотря на то, что GP не проверяет FK, порядок загрузки обеспечил целостность).

<img src="./assets/2026-10-19 003054.jpg" width="700">

## 5. Ограничения учебной модели

1. **Surrogate BK `hub_order`**: `ship_mode|postal_code|sales|quantity|discount` — 54 коллизии
   (9994 → 9940). В промышленной реализации нужен настоящий `order_id`.
2. **`fact_sales` — `DISTINCT ON`**: 23 коллизии (9994 → 9971) по полному набору из 4 хэшей;
   осознанное упрощение.
3. **`load_date = NOW()` в спутниках**: повторный запуск создаст новые версии
   (в промышленной реализации сравнивают `hash_diff` и вставляют только изменившиеся).
4. **FK в Greenplum 6 не проверяются** (`WARNING: referential integrity ... will not be enforced`);
   целостность обеспечена порядком загрузки (хабы → линки → спутники → факт) — проверено запросом
   `fact_rows_without_hub = 0`.
5. **`UNIQUE` на `*_bk` в хабах не ставится** — конфликтует с `DISTRIBUTED BY (*_hk)`;
   защита от дублей — `PRIMARY KEY` на `*_hk` + `WHERE NOT EXISTS`.