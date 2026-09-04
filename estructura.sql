-- =====================================================================
-- CAPSTONE POSTGRESQL - ESTRUCTURA Y CARGA
-- Dataset: Brazilian E-Commerce Public Dataset by Olist (Kaggle)
-- ~100k pedidos reales del marketplace Olist (Brasil, 2016-2018)
--
-- Ejecutar desde psql, parado en la carpeta del repo:
--   createdb capstone_project
--   psql -d capstone_project -v ON_ERROR_STOP=1 -f estructura.sql
--
-- Estrategia: staging en TEXT -> limpieza/casteo -> tablas finales tipadas.
-- Cargamos crudo primero porque los CSV traen celdas vacias en columnas
-- numericas y de fecha: un COPY directo a NUMERIC/TIMESTAMP fallaria.
-- =====================================================================

\set ON_ERROR_STOP on

--CREATE DATABASE capstone_project

-- ---------------------------------------------------------------------
-- 1. ESQUEMAS
-- ---------------------------------------------------------------------
DROP SCHEMA IF EXISTS staging CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;

CREATE SCHEMA staging;  -- datos crudos, tal cual vienen del CSV
CREATE SCHEMA core;     -- datos limpios y tipados, listos para analisis

SET search_path TO core, staging, public;

-- ---------------------------------------------------------------------
-- 2. STAGING: todo TEXT, sin restricciones
-- ---------------------------------------------------------------------
CREATE TABLE staging.customers_raw (
    customer_id              TEXT,
    customer_unique_id       TEXT,
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT
);

CREATE TABLE staging.sellers_raw (
    seller_id              TEXT,
    seller_zip_code_prefix TEXT,
    seller_city            TEXT,
    seller_state           TEXT
);

CREATE TABLE staging.products_raw (
    product_id                 TEXT,
    product_category_name      TEXT,
    product_name_lenght        TEXT,
    product_description_lenght TEXT,
    product_photos_qty         TEXT,
    product_weight_g           TEXT,
    product_length_cm          TEXT,
    product_height_cm          TEXT,
    product_width_cm           TEXT
);

CREATE TABLE staging.category_translation_raw (
    product_category_name         TEXT,
    product_category_name_english TEXT
);

CREATE TABLE staging.orders_raw (
    order_id                      TEXT,
    customer_id                   TEXT,
    order_status                  TEXT,
    order_purchase_timestamp      TEXT,
    order_approved_at             TEXT,
    order_delivered_carrier_date  TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

CREATE TABLE staging.order_items_raw (
    order_id            TEXT,
    order_item_id       TEXT,
    product_id          TEXT,
    seller_id           TEXT,
    shipping_limit_date TEXT,
    price               TEXT,
    freight_value       TEXT
);

CREATE TABLE staging.order_payments_raw (
    order_id             TEXT,
    payment_sequential   TEXT,
    payment_type         TEXT,
    payment_installments TEXT,
    payment_value        TEXT
);

CREATE TABLE staging.order_reviews_raw (
    review_id               TEXT,
    order_id                TEXT,
    review_score            TEXT,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT
);

CREATE TABLE staging.geolocation_raw (
    geolocation_zip_code_prefix TEXT,
    geolocation_lat             TEXT,
    geolocation_lng             TEXT,
    geolocation_city            TEXT,
    geolocation_state           TEXT
);

-- ---------------------------------------------------------------------
-- 3. CARGA DE CSV
-- \copy corre del lado del cliente: no necesita permisos de superusuario
-- ni que los archivos esten en el servidor.
-- ---------------------------------------------------------------------
\copy staging.customers_raw           FROM 'data/olist_customers_dataset.csv'          WITH (FORMAT csv, HEADER true)
\copy staging.sellers_raw             FROM 'data/olist_sellers_dataset.csv'            WITH (FORMAT csv, HEADER true)
\copy staging.products_raw            FROM 'data/olist_products_dataset.csv'           WITH (FORMAT csv, HEADER true)
\copy staging.orders_raw              FROM 'data/olist_orders_dataset.csv'             WITH (FORMAT csv, HEADER true)
\copy staging.order_items_raw         FROM 'data/olist_order_items_dataset.csv'        WITH (FORMAT csv, HEADER true)
\copy staging.order_payments_raw      FROM 'data/olist_order_payments_dataset.csv'     WITH (FORMAT csv, HEADER true)
\copy staging.order_reviews_raw       FROM 'data/olist_order_reviews_dataset.csv'      WITH (FORMAT csv, HEADER true)
--\copy staging.geolocation_raw         FROM 'data/olist_geolocation_dataset.csv'        WITH (FORMAT csv, HEADER true)
-- El CSV de traduccion viene con BOM UTF-8; ENCODING lo absorbe sin ensuciar la 1a fila.
\copy staging.category_translation_raw FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- ---------------------------------------------------------------------
-- 4. TABLAS FINALES (core) con tipos correctos y claves
-- Decisiones de tipado:
--   * zip_code_prefix como TEXT: son codigos, no cantidades. Guardarlos
--     como INTEGER perderia el cero inicial de "01037".
--   * dinero como NUMERIC(10,2): nunca FLOAT, que arrastra error de redondeo.
--   * fechas de evento como TIMESTAMP; la fecha estimada de entrega, que
--     en el origen no tiene hora util, como DATE.
-- ---------------------------------------------------------------------
CREATE TABLE core.customers (
    customer_id        CHAR(32) PRIMARY KEY,
    customer_unique_id CHAR(32) NOT NULL,  -- una persona puede tener varios customer_id
    zip_code_prefix    TEXT,
    city               TEXT,
    state              CHAR(2)
);

CREATE TABLE core.sellers (
    seller_id       CHAR(32) PRIMARY KEY,
    zip_code_prefix TEXT,
    city            TEXT,
    state           CHAR(2)
);

CREATE TABLE core.categories (
    category_name    TEXT PRIMARY KEY,
    category_name_en TEXT NOT NULL
);

CREATE TABLE core.products (
    product_id        CHAR(32) PRIMARY KEY,
    category_name     TEXT REFERENCES core.categories(category_name),
    name_length       INTEGER,
    description_length INTEGER,
    photos_qty        INTEGER,
    weight_g          INTEGER,
    length_cm         INTEGER,
    height_cm         INTEGER,
    width_cm          INTEGER
);

CREATE TABLE core.orders (
    order_id                CHAR(32) PRIMARY KEY,
    customer_id             CHAR(32) NOT NULL REFERENCES core.customers(customer_id),
    order_status            TEXT NOT NULL,
    purchase_ts             TIMESTAMP NOT NULL,
    approved_ts             TIMESTAMP,
    delivered_carrier_ts    TIMESTAMP,
    delivered_customer_ts   TIMESTAMP,
    estimated_delivery_date DATE
);

CREATE TABLE core.order_items (
    order_id            CHAR(32) NOT NULL REFERENCES core.orders(order_id),
    order_item_id       SMALLINT NOT NULL,  -- n de linea dentro del pedido
    product_id          CHAR(32) NOT NULL REFERENCES core.products(product_id),
    seller_id           CHAR(32) NOT NULL REFERENCES core.sellers(seller_id),
    shipping_limit_ts   TIMESTAMP,
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)  -- la PK es compuesta: un pedido tiene N lineas
);

CREATE TABLE core.order_payments (
    order_id           CHAR(32) NOT NULL REFERENCES core.orders(order_id),
    payment_sequential SMALLINT NOT NULL,  -- un pedido puede pagarse en varios medios
    payment_type       TEXT NOT NULL,
    installments       SMALLINT,
    payment_value      NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE core.order_reviews (
    review_id       CHAR(32) NOT NULL,
    order_id        CHAR(32) NOT NULL REFERENCES core.orders(order_id),
    review_score    SMALLINT NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title   TEXT,
    comment_message TEXT,
    creation_date   DATE,
    answer_ts       TIMESTAMP,
    PRIMARY KEY (review_id, order_id)  -- ver nota de deduplicacion mas abajo
);

CREATE TABLE core.geolocation (
    zip_code_prefix TEXT NOT NULL,
    lat             NUMERIC(11,8),
    lng             NUMERIC(11,8),
    city            TEXT,
    state           CHAR(2)
);

-- ---------------------------------------------------------------------
-- 5. LIMPIEZA Y CARGA A core
-- Orden obligado por las FK: catalogos -> maestros -> transaccionales.
-- ---------------------------------------------------------------------

-- Catalogo de categorias. Agregamos 'sin_categoria' a mano porque 610
-- productos vienen sin categoria y no queremos perderlos en el JOIN.
INSERT INTO core.categories (category_name, category_name_en)
SELECT DISTINCT
       btrim(product_category_name),
       btrim(product_category_name_english)
FROM   staging.category_translation_raw
WHERE  product_category_name IS NOT NULL
UNION
SELECT 'sin_categoria', 'uncategorized';

-- Las categorias que aparecen en products pero faltan en el diccionario de
-- traduccion se dan de alta con su nombre original, si no la FK las rechaza.
INSERT INTO core.categories (category_name, category_name_en)
SELECT DISTINCT btrim(p.product_category_name), btrim(p.product_category_name)
FROM   staging.products_raw p
WHERE  NULLIF(btrim(p.product_category_name), '') IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM core.categories c
                   WHERE c.category_name = btrim(p.product_category_name));

INSERT INTO core.customers (customer_id, customer_unique_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (customer_id)
       customer_id,
       customer_unique_id,
       -- El zip llega con largos irregulares; lo normalizamos a 5 digitos
       -- para que cruce contra geolocation sin sorpresas.
       lpad(NULLIF(btrim(customer_zip_code_prefix), ''), 5, '0'),
       initcap(COALESCE(NULLIF(btrim(customer_city), ''), 'desconocida')),
       upper(NULLIF(btrim(customer_state), ''))
FROM   staging.customers_raw
WHERE  customer_id IS NOT NULL;

INSERT INTO core.sellers (seller_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (seller_id)
       seller_id,
       lpad(NULLIF(btrim(seller_zip_code_prefix), ''), 5, '0'),
       initcap(COALESCE(NULLIF(btrim(seller_city), ''), 'desconocida')),
       upper(NULLIF(btrim(seller_state), ''))
FROM   staging.sellers_raw
WHERE  seller_id IS NOT NULL;

INSERT INTO core.products (product_id, category_name, name_length, description_length,
                           photos_qty, weight_g, length_cm, height_cm, width_cm)
SELECT DISTINCT ON (product_id)
       product_id,
       -- COALESCE sobre la categoria: preferimos una etiqueta explicita a un
       -- NULL que despues desaparezca silenciosamente en los GROUP BY.
       COALESCE(NULLIF(btrim(product_category_name), ''), 'sin_categoria'),
       -- NULLIF convierte la celda vacia en NULL antes del cast; sin esto
       -- el ::INTEGER revienta con "invalid input syntax".
       NULLIF(btrim(product_name_lenght), '')::INTEGER,
       NULLIF(btrim(product_description_lenght), '')::INTEGER,
       -- Sin foto declarada asumimos 0, que es el valor real de negocio.
       COALESCE(NULLIF(btrim(product_photos_qty), '')::INTEGER, 0),
       NULLIF(btrim(product_weight_g), '')::NUMERIC::INTEGER,
       NULLIF(btrim(product_length_cm), '')::NUMERIC::INTEGER,
       NULLIF(btrim(product_height_cm), '')::NUMERIC::INTEGER,
       NULLIF(btrim(product_width_cm), '')::NUMERIC::INTEGER
FROM   staging.products_raw
WHERE  product_id IS NOT NULL;

INSERT INTO core.orders (order_id, customer_id, order_status, purchase_ts, approved_ts,
                         delivered_carrier_ts, delivered_customer_ts, estimated_delivery_date)
SELECT DISTINCT ON (o.order_id)
       o.order_id,
       o.customer_id,
       lower(btrim(o.order_status)),
       NULLIF(btrim(o.order_purchase_timestamp), '')::TIMESTAMP,
       -- approved_at nulo no significa "no aprobado": son 160 registros donde
       -- el timestamp no quedo grabado. Lo imputamos con la fecha de compra
       -- para no romper los calculos de lead time.
       COALESCE(NULLIF(btrim(o.order_approved_at), '')::TIMESTAMP,
                NULLIF(btrim(o.order_purchase_timestamp), '')::TIMESTAMP),
       NULLIF(btrim(o.order_delivered_carrier_date), '')::TIMESTAMP,
       -- Aca NO imputamos: un pedido sin fecha de entrega al cliente es un
       -- pedido que no llego. Inventar un valor taparia el problema de negocio.
       NULLIF(btrim(o.order_delivered_customer_date), '')::TIMESTAMP,
       NULLIF(btrim(o.order_estimated_delivery_date), '')::TIMESTAMP::DATE
FROM   staging.orders_raw o
WHERE  o.order_id IS NOT NULL
  AND  NULLIF(btrim(o.order_purchase_timestamp), '') IS NOT NULL
  -- Descartamos huerfanos: sin cliente valido el pedido no aporta al analisis.
  AND  EXISTS (SELECT 1 FROM core.customers c WHERE c.customer_id = o.customer_id);

INSERT INTO core.order_items (order_id, order_item_id, product_id, seller_id,
                              shipping_limit_ts, price, freight_value)
SELECT DISTINCT ON (i.order_id, i.order_item_id::SMALLINT)
       i.order_id,
       i.order_item_id::SMALLINT,
       i.product_id,
       i.seller_id,
       NULLIF(btrim(i.shipping_limit_date), '')::TIMESTAMP,
       -- Precio y flete son columnas criticas: un NULL aca sesgaria toda
       -- suma de facturacion, asi que COALESCE a 0 y filtramos precios <= 0.
       COALESCE(NULLIF(btrim(i.price), '')::NUMERIC(10,2), 0),
       COALESCE(NULLIF(btrim(i.freight_value), '')::NUMERIC(10,2), 0)
FROM   staging.order_items_raw i
WHERE  i.order_id IS NOT NULL
  AND  COALESCE(NULLIF(btrim(i.price), '')::NUMERIC, 0) > 0
  AND  EXISTS (SELECT 1 FROM core.orders    o WHERE o.order_id   = i.order_id)
  AND  EXISTS (SELECT 1 FROM core.products  p WHERE p.product_id = i.product_id)
  AND  EXISTS (SELECT 1 FROM core.sellers   s WHERE s.seller_id  = i.seller_id);

INSERT INTO core.order_payments (order_id, payment_sequential, payment_type,
                                 installments, payment_value)
SELECT DISTINCT ON (p.order_id, p.payment_sequential::SMALLINT)
       p.order_id,
       p.payment_sequential::SMALLINT,
       -- 'not_defined' es el marcador de basura del origen: lo unificamos
       -- con los nulos bajo una unica etiqueta 'desconocido'.
       COALESCE(NULLIF(NULLIF(btrim(p.payment_type), ''), 'not_defined'), 'desconocido'),
       -- 0 cuotas es un dato imposible; lo tratamos como pago en 1 cuota.
       NULLIF(COALESCE(NULLIF(btrim(p.payment_installments), '')::SMALLINT, 1), 0),
       COALESCE(NULLIF(btrim(p.payment_value), '')::NUMERIC(10,2), 0)
FROM   staging.order_payments_raw p
WHERE  p.order_id IS NOT NULL
  AND  EXISTS (SELECT 1 FROM core.orders o WHERE o.order_id = p.order_id);

-- El CSV de reviews trae review_id repetidos (una misma resena asociada a mas
-- de un pedido) y pares (review_id, order_id) duplicados exactos. Nos quedamos
-- con la ultima respuesta de cada par para no inflar los promedios de score.
INSERT INTO core.order_reviews (review_id, order_id, review_score, comment_title,
                                comment_message, creation_date, answer_ts)
SELECT DISTINCT ON (r.review_id, r.order_id)
       r.review_id,
       r.order_id,
       r.review_score::SMALLINT,
       NULLIF(btrim(r.review_comment_title), ''),
       NULLIF(btrim(r.review_comment_message), ''),
       NULLIF(btrim(r.review_creation_date), '')::TIMESTAMP::DATE,
       NULLIF(btrim(r.review_answer_timestamp), '')::TIMESTAMP
FROM   staging.order_reviews_raw r
WHERE  r.review_id IS NOT NULL
  AND  NULLIF(btrim(r.review_score), '')::SMALLINT BETWEEN 1 AND 5
  AND  EXISTS (SELECT 1 FROM core.orders o WHERE o.order_id = r.order_id)
ORDER  BY r.review_id, r.order_id,
          NULLIF(btrim(r.review_answer_timestamp), '')::TIMESTAMP DESC NULLS LAST;

-- Geolocation trae ~1M de filas con muchos puntos por CP. Guardamos el
-- centroide por codigo postal: para analisis por zona alcanza y evita la
-- explosion de filas al unir contra clientes.
INSERT INTO core.geolocation (zip_code_prefix, lat, lng, city, state)
SELECT lpad(NULLIF(btrim(geolocation_zip_code_prefix), ''), 5, '0'),
       ROUND(AVG(NULLIF(btrim(geolocation_lat), '')::NUMERIC), 8),
       ROUND(AVG(NULLIF(btrim(geolocation_lng), '')::NUMERIC), 8),
       initcap(MIN(btrim(geolocation_city))),
       upper(MIN(btrim(geolocation_state)))
FROM   staging.geolocation_raw
WHERE  NULLIF(btrim(geolocation_zip_code_prefix), '') IS NOT NULL
  -- Recorte al bounding box de Brasil: el origen tiene puntos fuera del pais.
  AND  NULLIF(btrim(geolocation_lat), '')::NUMERIC BETWEEN -34 AND 6
  AND  NULLIF(btrim(geolocation_lng), '')::NUMERIC BETWEEN -74 AND -34
GROUP  BY 1;

ALTER TABLE core.geolocation ADD PRIMARY KEY (zip_code_prefix);

-- ---------------------------------------------------------------------
-- 6. INDICES
-- Solo sobre las columnas que se usan en JOIN o WHERE del analisis.
-- Las PK ya crean su indice; no repetimos.
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_customer      ON core.orders (customer_id);
CREATE INDEX idx_orders_purchase_ts   ON core.orders (purchase_ts);
CREATE INDEX idx_orders_status        ON core.orders (order_status);
CREATE INDEX idx_items_product        ON core.order_items (product_id);
CREATE INDEX idx_items_seller         ON core.order_items (seller_id);
CREATE INDEX idx_reviews_order        ON core.order_reviews (order_id);
CREATE INDEX idx_customers_unique_id  ON core.customers (customer_unique_id);

ANALYZE;  -- refresca estadisticas para que el planner elija bien

-- ---------------------------------------------------------------------
-- 7. VERIFICACION DE CARGA
-- Comparar staging vs core es el control basico contra perdida silenciosa.
-- ---------------------------------------------------------------------
SELECT 'customers'  AS tabla, (SELECT count(*) FROM staging.customers_raw)      AS filas_raw, count(*) AS filas_core FROM core.customers
UNION ALL SELECT 'sellers',   (SELECT count(*) FROM staging.sellers_raw),               count(*) FROM core.sellers
UNION ALL SELECT 'products',  (SELECT count(*) FROM staging.products_raw),              count(*) FROM core.products
UNION ALL SELECT 'orders',    (SELECT count(*) FROM staging.orders_raw),                count(*) FROM core.orders
UNION ALL SELECT 'items',     (SELECT count(*) FROM staging.order_items_raw),           count(*) FROM core.order_items
UNION ALL SELECT 'payments',  (SELECT count(*) FROM staging.order_payments_raw),        count(*) FROM core.order_payments
UNION ALL SELECT 'reviews',   (SELECT count(*) FROM staging.order_reviews_raw),         count(*) FROM core.order_reviews
UNION ALL SELECT 'geoloc',    (SELECT count(*) FROM staging.geolocation_raw),           count(*) FROM core.geolocation
ORDER BY 1;
