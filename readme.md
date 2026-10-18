# Итоговое задание, модуль 1 — Data Vault в Greenplum

**Выполнил:** Третьяков Александр Юрьевич

## Содержимое
- [`task_final.md`](./task_final.md) — отчёт по заданию
- [`docker-compose.yml`](./docker-compose.yml) — инфраструктура (Greenplum 6.19.2)
- [`sql/01_ddl.sql`](./sql/01_ddl.sql) — DDL Data Vault
- [`sql/02_load.sql`](./sql/02_load.sql) — загрузка из `data/SampleSuperstore.csv`

## Как воспроизвести
```bash
docker compose up -d
docker exec -i -u gpadmin gp_superstore psql -h localhost -U gpadmin -d gpadmin -f /sql/01_ddl.sql
docker exec -i -u gpadmin gp_superstore psql -h localhost -U gpadmin -d gpadmin -f /sql/02_load.sql