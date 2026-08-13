-- Esquema mínimo para el laboratorio: pedidos (service-a) e inventario (service-b).
-- Se ejecuta automáticamente al iniciar el contenedor postgres (docker-entrypoint-initdb.d).

CREATE TABLE IF NOT EXISTS orders (
    id         VARCHAR(20) PRIMARY KEY,
    sku        VARCHAR(50) NOT NULL,
    quantity   INTEGER NOT NULL DEFAULT 1,
    status     VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inventory (
    sku             VARCHAR(50) PRIMARY KEY,
    available_units INTEGER NOT NULL DEFAULT 0,
    warehouse       VARCHAR(50) NOT NULL DEFAULT 'WH-BOG-01'
);

INSERT INTO orders (id, sku, quantity, status) VALUES
    ('ord-1001', 'sku-teclado-mk',  1, 'delivered'),
    ('ord-1002', 'sku-mouse-pro',   2, 'pending'),
    ('ord-1003', 'sku-monitor-4k',  1, 'shipped'),
    ('ord-1004', 'sku-webcam-hd',   1, 'pending'),
    ('ord-1005', 'sku-audifonos-x', 3, 'cancelled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO inventory (sku, available_units, warehouse) VALUES
    ('sku-teclado-mk',  42, 'WH-BOG-01'),
    ('sku-mouse-pro',   87, 'WH-BOG-01'),
    ('sku-monitor-4k',   6, 'WH-MED-02'),
    ('sku-webcam-hd',   15, 'WH-BOG-01'),
    ('sku-audifonos-x', 30, 'WH-MED-02')
ON CONFLICT (sku) DO NOTHING;
