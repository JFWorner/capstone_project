/*
 ********************************************************************************
 *                   	Capstone Project (analisis.sql)
 * 
 * SQL: Postgres
 * Author: Juan Francisco Martorello
 * Curso: SQL Flex
 * Nota: Se usan los datos de e-comerce de Kaggle 
 * 
 ********************************************************************************
*/

-- LIMPIEZA: cuanto pesan los datos faltantes que quedaron etiquetados en la carga
-- Si fueran significativos, las conclusiones por categoria o entrega no serian confiables

SELECT round(100.0 * (SELECT count(*) FROM products WHERE category = 'sin_categoria')/ (SELECT count(*) FROM products), 1) AS pct_productos_sin_categoria,
       round(100.0 * count(*) FILTER (WHERE delivered_ts IS NULL) / count(*), 1) AS pct_pedidos_sin_entrega
FROM orders;

-- Base comun: una fila por linea vendida. Se excluyen cancelados y no disponibles porque no generaron ingreso y contarlos inflaria la facturacion
-- El grano es order_items, asi que los JOIN hacia arriba (N:1) no duplican filas

CREATE OR REPLACE VIEW sales AS
SELECT o.order_id, o.purchase_ts, c.customer_unique_id, c.state, i.product_id, p.category, i.price
FROM order_items i
JOIN orders o USING (order_id)
JOIN customers c USING (customer_id)
JOIN products p USING (product_id)
WHERE o.status NOT IN ('canceled', 'unavailable');

-- 1. TOP 5 CLIENTES POR GASTO
-- Se agrupa por customer_unique_id porque customer_id cambia en cada pedido:
-- agrupar por el haria parecer que nadie compra dos veces
-- max(state) y no GROUP BY state: 37 clientes compraron desde mas de un estado y su gasto se partiria

SELECT customer_unique_id, max(state) AS state, count(DISTINCT order_id) AS pedidos, sum(price) AS gasto_total
FROM sales
GROUP BY customer_unique_id
ORDER BY gasto_total DESC
LIMIT 5;

-- 2. VENTAS POR MES
-- LAG compara contra el mes anterior para distinguir crecimiento real de estacionalidad
-- El primer mes da NULL a proposito: no tiene mes previo contra el cual comparar
-- Se acota a ene-2017..ago-2018: 2016 y sep-2018 tienen carga parcial (meses con 1-2 pedidos
-- o directamente ausentes) y LAG compararia meses no consecutivos

WITH mensual AS (
    SELECT date_trunc('month', purchase_ts)::DATE AS mes,
           count(DISTINCT order_id) AS pedidos,
           sum(price) AS ventas
    FROM sales
    WHERE purchase_ts >= '2017-01-01' AND purchase_ts < '2018-09-01'
    GROUP BY 1
)
SELECT *, round(100 * (ventas / lag(ventas) OVER (ORDER BY mes) - 1), 1) AS var_pct
FROM mensual
ORDER BY mes;

-- 2b. DIAS PICO
-- Explica el salto de nov-2017, el dia con mas pedidos coincide con el Black Friday
-- (24/11/2017) el crecimiento de ese mes es estacional

SELECT purchase_ts::DATE AS dia, count(DISTINCT order_id) AS pedidos
FROM sales
GROUP BY 1
ORDER BY pedidos DESC
LIMIT 5;

-- 3. LOS 3 PRODUCTOS MENOS VENDIDOS
-- LEFT JOIN desde products para no perder los que nunca se vendieron (COALESCE a 0)
-- La ultima columna dimensiona la cola larga: cuantos productos comparten ese piso de 0-1 unidades

SELECT p.product_id, p.category,
       count(s.product_id) AS unidades,
       COALESCE(sum(s.price), 0) AS ingresos,
       count(CASE WHEN count(s.product_id) <= 1 THEN 1 END) OVER () AS productos_con_0_o_1_venta
FROM products p
LEFT JOIN sales s USING (product_id)
GROUP BY p.product_id, p.category
ORDER BY unidades, ingresos, p.product_id  -- hay cientos de empates en 0, product_id hace reproducible el resultado
LIMIT 3;

-- 4. RANKING DE CATEGORIAS
-- RANK sobre ingresos y participacion acumulada para ver cuantas categorias
-- sostienen el negocio (Pareto) y donde concentrar inventario y marketing

SELECT rank() OVER (ORDER BY sum(price) DESC) AS puesto,
       category,
       count(DISTINCT order_id) AS pedidos,
       sum(price) AS ingresos,
       round(100 * sum(sum(price)) OVER (ORDER BY sum(price) DESC) / sum(sum(price)) OVER (), 1) AS pct_acumulado
FROM sales
GROUP BY category
ORDER BY puesto
LIMIT 10;

-- 5. ENTREGAS TARDIAS POR ESTADO
-- Solo pedidos entregados: los que no tienen fecha de entrega no se pueden evaluar
-- HAVING descarta estados con pocos pedidos

SELECT c.state,
       count(*) AS entregados,
       round(100.0 * count(*) FILTER (WHERE o.delivered_ts::DATE > o.estimated_delivery) / count(*), 1) AS pct_tarde,
       round(avg(o.delivered_ts::DATE - o.purchase_ts::DATE), 1) AS dias_promedio,
       CASE WHEN avg(o.delivered_ts::DATE - o.purchase_ts::DATE) > 20 THEN 'critico'
            WHEN avg(o.delivered_ts::DATE - o.purchase_ts::DATE) > 12 THEN 'lento'
            ELSE 'normal' END AS nivel_servicio
FROM orders o
JOIN customers c USING (customer_id)
WHERE o.delivered_ts IS NOT NULL
GROUP BY c.state
HAVING count(*) >= 500
ORDER BY pct_tarde DESC;
