/*
 ********************************************************************************
 *                   	Capstone Project (estructura.sql)
 * 
 * SQL: Postgres
 * Author: Juan Francisco Martorello
 * Curso: SQL Flex
 * Nota: Se usan los datos de e-comerce de Kaggle 
 * 
 ********************************************************************************
*/

-- Ejecutar desde la carpeta del repo:  psql -U postgres -f estructura.sql

\set ON_ERROR_STOP on
\encoding UTF8

SELECT 'CREATE DATABASE capstone_project'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'capstone_project')\gexec
\c capstone_project

-- 1. STAGING: todo TEXT, porque los CSV traen celdas vacias en fechas y
-- categorias y un COPY directo a columnas tipadas no permitiria auditarlas.

-- CASCADE: la vista sales (analisis.sql) depende de estas tablas y bloquearia el DROP al re-ejecutar.
DROP TABLE IF EXISTS order_items, orders, products, customers CASCADE;

CREATE TEMP TABLE customers_raw (customer_id TEXT, customer_unique_id TEXT, zip TEXT, city TEXT, state TEXT);
CREATE TEMP TABLE products_raw (product_id TEXT, category TEXT, name_len TEXT, desc_len TEXT, photos TEXT, weight TEXT, length TEXT, height TEXT, width TEXT);
CREATE TEMP TABLE categories_raw (category TEXT, category_en TEXT);
CREATE TEMP TABLE orders_raw (order_id TEXT, customer_id TEXT, status TEXT, purchase TEXT, approved TEXT, carrier TEXT, delivered TEXT, estimated TEXT);
CREATE TEMP TABLE items_raw (order_id TEXT, order_item_id TEXT, product_id TEXT, seller_id TEXT, shipping_limit TEXT, price TEXT, freight TEXT);

\copy customers_raw FROM 'data/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER)
\copy products_raw FROM 'data/olist_products_dataset.csv' WITH (FORMAT csv, HEADER)
\copy categories_raw FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER)
\copy orders_raw FROM 'data/olist_orders_dataset.csv' WITH (FORMAT csv, HEADER)
\copy items_raw FROM 'data/olist_order_items_dataset.csv' WITH (FORMAT csv, HEADER)

-- 2. DIAGNOSTICO: nulos en columnas criticas antes de decidir como tratarlos.

SELECT (SELECT count(*) FROM products_raw WHERE category IS NULL) AS productos_sin_categoria,
       (SELECT count(*) FROM orders_raw WHERE purchase IS NULL) AS pedidos_sin_fecha_compra,
       (SELECT count(*) FROM orders_raw WHERE delivered IS NULL) AS pedidos_sin_fecha_entrega,
       (SELECT count(*) FROM items_raw WHERE price IS NULL) AS items_sin_precio,
       (SELECT count(*) FROM items_raw WHERE freight IS NULL) AS items_sin_flete;

-- 3. TABLAS FINALES. Dinero en NUMERIC (FLOAT arrastra error de redondeo).

CREATE TABLE customers (
    customer_id        CHAR(32) PRIMARY KEY,   -- Olist genera uno por pedido
    customer_unique_id CHAR(32) NOT NULL,      -- la persona real
    city               TEXT,
    state              CHAR(2)
);

CREATE TABLE products (
    product_id CHAR(32) PRIMARY KEY,
    category   TEXT NOT NULL
);

CREATE TABLE orders (
    order_id           CHAR(32) PRIMARY KEY,
    customer_id        CHAR(32) NOT NULL REFERENCES customers,
    status             TEXT NOT NULL,
    purchase_ts        TIMESTAMP NOT NULL,
    delivered_ts       TIMESTAMP,
    estimated_delivery DATE
);

CREATE TABLE order_items (
    order_id      CHAR(32) REFERENCES orders,
    order_item_id SMALLINT,
    product_id    CHAR(32) NOT NULL REFERENCES products,
    price         NUMERIC(10,2) NOT NULL CHECK (price > 0),
    freight       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

-- 4. LIMPIEZA Y CARGA

INSERT INTO customers
SELECT customer_id, customer_unique_id, initcap(btrim(city)), upper(state)
FROM customers_raw;

-- Categoria: traduccion al ingles, si no existe el nombre original, y si el
-- producto no trae ninguna, una etiqueta explicita. Un NULL desapareceria en
-- silencio de los GROUP BY y subestimaria las ventas.

INSERT INTO products
SELECT p.product_id, COALESCE(c.category_en, p.category, 'sin_categoria')
FROM products_raw p
LEFT JOIN categories_raw c USING (category);

-- delivered_ts NO se imputa: sin fecha de entrega el pedido no llego al cliente
-- (en transito, cancelado, sin stock); inventarle una fecha falsearia los plazos.

INSERT INTO orders
SELECT order_id, customer_id, status, purchase::TIMESTAMP, delivered::TIMESTAMP, estimated::DATE
FROM orders_raw;

-- Flete ausente = envio sin costo, por eso 0. El precio no se imputa: sin
-- precio la linea no es una venta medible y el CHECK la rechaza.

INSERT INTO order_items
SELECT order_id, order_item_id::SMALLINT, product_id, price::NUMERIC, COALESCE(freight::NUMERIC, 0)
FROM items_raw;

-- Indices solo en las FK usadas en los JOIN; las PK ya tienen el suyo.

CREATE INDEX ON orders (customer_id);
CREATE INDEX ON order_items (product_id);

-- 5. CONTROL: lo cargado debe coincidir con los CSV.
SELECT (SELECT count(*) FROM customers) AS customers,
       (SELECT count(*) FROM products) AS products,
       (SELECT count(*) FROM orders) AS orders,
       (SELECT count(*) FROM order_items) AS order_items;
