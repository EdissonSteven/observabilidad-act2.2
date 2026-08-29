-- Esquema del laboratorio: pedidos (service-a), inventario (service-b) y
-- clientes (data-service, Módulo A del laboratorio integrador).
-- Se ejecuta automáticamente al iniciar el contenedor postgres (docker-entrypoint-initdb.d).
--
-- Nota de despliegue real: en Cloud SQL / RDS, `customers` vive en la MISMA
-- instancia que `orders`/`inventory` para este laboratorio (una sola base de
-- datos gestionada por nube, ver iac/terraform/{gcp,aws}) -- separarla en su
-- propia instancia es una mejora de aislamiento de blast radius que queda
-- documentada como trabajo futuro en docs/madurez-observabilidad.md
-- (dominio 8, roadmap).

CREATE TABLE IF NOT EXISTS customers (
    id        VARCHAR(20) PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    tier      VARCHAR(20) NOT NULL DEFAULT 'standard',
    country   VARCHAR(2) NOT NULL DEFAULT 'CO'
);

CREATE TABLE IF NOT EXISTS orders (
    id          VARCHAR(20) PRIMARY KEY,
    sku         VARCHAR(50) NOT NULL,
    customer_id VARCHAR(20) NOT NULL REFERENCES customers(id),
    quantity    INTEGER NOT NULL DEFAULT 1,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inventory (
    sku             VARCHAR(50) PRIMARY KEY,
    available_units INTEGER NOT NULL DEFAULT 0,
    warehouse       VARCHAR(50) NOT NULL DEFAULT 'WH-BOG-01'
);

INSERT INTO customers (id, full_name, tier, country) VALUES
    ('cus-001', 'Laura Restrepo',  'gold',     'CO'),
    ('cus-002', 'Andrés Higuita',  'standard', 'CO'),
    ('cus-003', 'María Fernanda',  'platinum', 'MX'),
    ('cus-004', 'Julián Quintero', 'standard', 'CO'),
    ('cus-005', 'Sara Contreras',  'gold',     'PE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO orders (id, sku, customer_id, quantity, status) VALUES
    ('ord-1001', 'sku-teclado-mk',  'cus-001', 1, 'delivered'),
    ('ord-1002', 'sku-mouse-pro',   'cus-002', 2, 'pending'),
    ('ord-1003', 'sku-monitor-4k',  'cus-003', 1, 'shipped'),
    ('ord-1004', 'sku-webcam-hd',   'cus-004', 1, 'pending'),
    ('ord-1005', 'sku-audifonos-x', 'cus-005', 3, 'cancelled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO inventory (sku, available_units, warehouse) VALUES
    ('sku-teclado-mk',  42, 'WH-BOG-01'),
    ('sku-mouse-pro',   87, 'WH-BOG-01'),
    ('sku-monitor-4k',   6, 'WH-MED-02'),
    ('sku-webcam-hd',   15, 'WH-BOG-01'),
    ('sku-audifonos-x', 30, 'WH-MED-02')
ON CONFLICT (sku) DO NOTHING;
