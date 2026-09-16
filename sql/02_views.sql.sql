/* ============================================================
   Retail Analytics — Semantic Layer (Star Schema)
   Database : itversity_retail_db (PostgreSQL 14)
  

   These views are what Power BI imports. Business logic lives
   here, in version control, instead of being buried inside a
   .pbix file where nobody can review it.

   Run once:  psql -U postgres -d itversity_retail_db -f 02_views.sql
   (requires CREATE permission on the database)
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS bi;


/* ------------------------------------------------------------
   DIMENSION: Date
   A proper date table is mandatory in Power BI — DAX time
   intelligence (SAMEPERIODLASTYEAR, DATESYTD, ...) will not work
   without one. Generated from the actual order date range.
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW bi.dim_date AS
WITH bounds AS (
    SELECT
        DATE_TRUNC('year', MIN(order_date))::date                       AS start_date,
        (DATE_TRUNC('year', MAX(order_date)) + INTERVAL '1 year -1 day')::date AS end_date
    FROM orders
)
SELECT
    d::date                                     AS date_key,
    EXTRACT(YEAR    FROM d)::int                AS year,
    EXTRACT(QUARTER FROM d)::int                AS quarter,
    'Q' || EXTRACT(QUARTER FROM d)::int         AS quarter_name,
    EXTRACT(MONTH   FROM d)::int                AS month_number,
    TRIM(TO_CHAR(d, 'Month'))                   AS month_name,
    TRIM(TO_CHAR(d, 'Mon'))                     AS month_short,
    TO_CHAR(d, 'YYYY-MM')                       AS year_month,
    EXTRACT(DAY     FROM d)::int                AS day_of_month,
    EXTRACT(ISODOW  FROM d)::int                AS day_of_week,
    TRIM(TO_CHAR(d, 'Day'))                     AS day_name,
    TRIM(TO_CHAR(d, 'Dy'))                      AS day_short,
    EXTRACT(WEEK    FROM d)::int                AS week_of_year,
    (EXTRACT(ISODOW FROM d) >= 6)               AS is_weekend
FROM bounds, GENERATE_SERIES(bounds.start_date, bounds.end_date, INTERVAL '1 day') AS d;


/* ------------------------------------------------------------
   DIMENSION: Product
   Flattens the products -> categories -> departments hierarchy
   into one wide, short table. Drops product_description (empty
   in this dataset) and product_image (a URL, not analytical).

   LEFT JOIN is deliberate. 264 products reference category_id 59,
   which does not exist in the categories table. An inner join
   silently drops them and the dimension falls from 1,345 to 1,081
   rows, understating catalogue coverage. COALESCE labels them
   explicitly and has_data_issue flags them for filtering.
   See 01_exploration.sql sections 0.3 and 0.4.
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW bi.dim_product AS
SELECT
    p.product_id,
    p.product_name,
    c.category_id,
    COALESCE(c.category_name,   'Category 59 (missing from source)') AS category_name,
    d.department_id,
    COALESCE(d.department_name, 'Unassigned')                        AS department_name,
    p.product_price::numeric(10,2)              AS list_price,
    CASE
        WHEN p.product_price <  50  THEN 'Budget (< $50)'
        WHEN p.product_price < 150  THEN 'Mid ($50-150)'
        WHEN p.product_price < 300  THEN 'Premium ($150-300)'
        ELSE                             'Luxury ($300+)'
    END                                         AS price_band,
    (c.category_id IS NULL)                     AS has_data_issue
FROM products p
LEFT JOIN categories  c ON p.product_category_id    = c.category_id
LEFT JOIN departments d ON c.category_department_id = d.department_id;


/* ------------------------------------------------------------
   DIMENSION: Customer
   Excludes customer_email and customer_password — both are
   masked in this dataset, and credentials never belong in a
   BI model regardless.
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW bi.dim_customer AS
SELECT
    cu.customer_id,
    cu.customer_fname                                   AS first_name,
    cu.customer_lname                                   AS last_name,
    cu.customer_fname || ' ' || cu.customer_lname       AS customer_name,
    cu.customer_city                                    AS city,
    cu.customer_state                                   AS state,
    cu.customer_zipcode                                 AS zipcode,
    cu.customer_state || ', ' || cu.customer_city       AS city_state
FROM customers cu;


/* ------------------------------------------------------------
   FACT: Sales
   Grain = one row per order line item.
   Keeps cancelled and fraud orders so the dashboard can report
   on them; a DAX measure filters them out of revenue.
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW bi.fact_sales AS
SELECT
    oi.order_item_id                                    AS sales_key,
    o.order_id,
    o.order_date::date                                  AS order_date,
    o.order_customer_id                                 AS customer_id,
    oi.order_item_product_id                            AS product_id,
    o.order_status,
    oi.order_item_quantity                              AS quantity,
    oi.order_item_product_price::numeric(10,2)          AS unit_price,
    oi.order_item_subtotal::numeric(12,2)               AS revenue,
    (o.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD')) AS is_valid_sale
FROM order_items oi
JOIN orders o ON oi.order_item_order_id = o.order_id;


/* ------------------------------------------------------------
   DIMENSION: Order Status
   A small lookup so the dashboard can group statuses and sort
   them in a sensible order rather than alphabetically.
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW bi.dim_order_status AS
SELECT DISTINCT
    order_status,
    CASE order_status
        WHEN 'COMPLETE'         THEN 'Fulfilled'
        WHEN 'CLOSED'           THEN 'Fulfilled'
        WHEN 'PROCESSING'       THEN 'In Progress'
        WHEN 'PENDING'          THEN 'In Progress'
        WHEN 'PENDING_PAYMENT'  THEN 'Awaiting Payment'
        WHEN 'PAYMENT_REVIEW'   THEN 'Awaiting Payment'
        WHEN 'ON_HOLD'          THEN 'Blocked'
        WHEN 'CANCELED'         THEN 'Lost'
        WHEN 'SUSPECTED_FRAUD'  THEN 'Lost'
        ELSE 'Other'
    END AS status_group,
    CASE order_status
        WHEN 'COMPLETE'        THEN 1  WHEN 'CLOSED'          THEN 2
        WHEN 'PROCESSING'      THEN 3  WHEN 'PENDING'         THEN 4
        WHEN 'PENDING_PAYMENT' THEN 5  WHEN 'PAYMENT_REVIEW'  THEN 6
        WHEN 'ON_HOLD'         THEN 7  WHEN 'CANCELED'        THEN 8
        WHEN 'SUSPECTED_FRAUD' THEN 9  ELSE 99
    END AS sort_order
FROM orders;


/* ------------------------------------------------------------
   Grant read access (adjust the role name if yours differs)
   ------------------------------------------------------------ */
GRANT USAGE ON SCHEMA bi TO itversity_retail_user;
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO itversity_retail_user;


/* ------------------------------------------------------------
   Verify
   ------------------------------------------------------------ */
-- SELECT COUNT(*) FROM bi.fact_sales;    -- expect 172,198
-- SELECT COUNT(*) FROM bi.dim_customer;  -- expect  12,435
-- SELECT COUNT(*) FROM bi.dim_product;   -- expect   1,345 (NOT 1,081)
-- SELECT COUNT(*) FROM bi.dim_date;      -- expect     730
-- SELECT table_name FROM information_schema.views WHERE table_schema = 'bi';
