-- Esquema y datos de prueba SOLO de `customers`, para Cloud SQL / RDS
-- (la base de datos PROPIA de data-service, separada de orders/inventory --
-- ver iac/terraform/gcp/cloudsql.tf e iac/terraform/aws/rds.tf).
--
-- Por qué existe este archivo aparte de scripts/init-db.sql:
-- scripts/init-db.sql se ejecuta automáticamente vía
-- /docker-entrypoint-initdb.d/ (docker-compose local Y el Postgres del
-- clúster en iac/terraform/gcp/postgres.tf), pero Cloud SQL no tiene ese
-- mecanismo de auto-inicialización (confirmado como hallazgo real de este
-- laboratorio, 2026-08-30: `google_sql_database.customersdb` en
-- cloudsql.tf crea la base vacía, y data-service falla con
-- 'relation "customers" does not exist' al primer query). Ejecutar
-- scripts/init-db.sql completo contra Cloud SQL crearía además
-- `orders`/`inventory` (con el `REFERENCES customers(id)` de `orders`) en
-- la base equivocada -- este archivo aísla solo lo que corresponde a
-- `customers`, mismo dato exacto (mismos 5 clientes, incluyendo
-- 'cus-002'/Andrés Higuita, el mismo que referencia ord-1002 en
-- scripts/init-db.sql) para que las pruebas de traza de 3 saltos sean
-- consistentes entre el flujo 100% local y el flujo real en la nube.
--
-- Ejecutado por iac/terraform/gcp/cloudsql_seed.tf vía un Kubernetes Job
-- de una sola vez (kubernetes_job_v1), no automáticamente en cada
-- arranque -- ver el comentario de ese archivo para el porqué.

CREATE TABLE IF NOT EXISTS customers (
    id        VARCHAR(20) PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    tier      VARCHAR(20) NOT NULL DEFAULT 'standard',
    country   VARCHAR(2) NOT NULL DEFAULT 'CO'
);

INSERT INTO customers (id, full_name, tier, country) VALUES
    ('cus-001', 'Laura Restrepo',  'gold',     'CO'),
    ('cus-002', 'Andrés Higuita',  'standard', 'CO'),
    ('cus-003', 'María Fernanda',  'platinum', 'MX'),
    ('cus-004', 'Julián Quintero', 'standard', 'CO'),
    ('cus-005', 'Sara Contreras',  'gold',     'PE')
ON CONFLICT (id) DO NOTHING;
